// Remote.swift
// Port of com.linote.diffstudio.ssh.Remote (Java, MIT).
//
// Port of ota_desktop.py: SSH updater with review token, host-key
// pinning and detached device transaction.
//
// Transport: NIOSSH (apple/swift-nio-ssh 0.12.0) via Swift Package
// Manager. Verified against the real NIOSSH API (SSHClientConfiguration,
// NIOSSHHandler.createChannel with a channel initializer, SSHChannelData
// with IOData payloads, SSHChannelRequestEvent.ExitStatus as an inbound
// user event, SimplePasswordDelegate).
//
// Authentication gap (documented, not faked): NIOSSH 0.12.0 offers
// password and public-key auth only — there is no keyboard-interactive
// offer. Java's JSch tried keyboard-interactive as a second round;
// here password is offered once (SimplePasswordDelegate) and then no
// further offer is made. Devices that require keyboard-interactive
// will fail to authenticate.
//
// Cryptographic gap (documented, not faked): NIOSSH supports modern
// algorithms only (Ed25519/ECDSA, AES-GCM, x25519). Java's JSch was
// configured with legacy algorithms for old Dropbear builds
// (diffie-hellman-group1/group14-sha1, ssh-rsa/ssh-dss host keys,
// CBC ciphers, hmac-sha1/md5). A device whose Dropbear offers only
// those legacy algorithms will fail to negotiate with NIOSSH, and
// connect() will surface that failure instead of pretending success.
// There is no fallback: silently downgrading would be a security
// regression.

import Foundation
import NIO
import NIOSSH

public final class Remote {
    /// Progress events: {stage: "upload", done: Int64, total: Int64}.
    public typealias Events = (JsonObject) -> Void

    private let root: URL
    private let events: Events
    private let group: MultiThreadedEventLoopGroup
    private let lock = NSLock()

    private var review: JsonObject?
    private var runtimeSession: JsonObject?
    private var archivePath: URL?
    private var activated = Set<String>()
    private var pendingReboot: JsonObject?

    public init(root: URL, events: Events? = nil) {
        self.root = root
        self.events = events ?? { _ in }
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        try? group.syncShutdownGracefully()
    }

    private func tokenHex(_ n: Int) -> String {
        Py.hex((0..<n).map { _ in UInt8.random(in: 0...255) })
    }

    // MARK: - SSH plumbing

    public final class Client {
        let channel: Channel
        let sshHandler: NIOSSHHandler
        public let hostKeySha256: String

        init(channel: Channel, sshHandler: NIOSSHHandler, hostKeySha256: String) {
            self.channel = channel
            self.sshHandler = sshHandler
            self.hostKeySha256 = hostKeySha256
        }

        public func close() {
            _ = channel.close()
        }
    }

    /// Accepts any host key but records its SHA-256 fingerprint, which
    /// the caller pins (Java used StrictHostKeyChecking=no with the
    /// same in-app pinning between probe and apply).
    private final class RecordingServerAuthDelegate: NIOSSHClientServerAuthenticationDelegate {
        var fingerprint = ""
        var keyBlob = Data()

        func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
            // The fingerprint is the SHA-256 of the host-key blob as it
            // appears on the wire (algorithm string + key bytes), the
            // same value OpenSSH prints as SHA256:... and Java computed
            // from session.getHostKey().getKey(). NIOSSH exposes the
            // key as an OpenSSH string "<alg> <base64>"; the base64
            // part decodes to exactly that wire blob.
            let parts = String(openSSHPublicKey: hostKey).split(separator: " ")
            if parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) {
                keyBlob = blob
                fingerprint = Py.sha256Hex(blob)
            }
            validationCompletePromise.succeed(())
        }
    }

    public func connect(host: String, password: String) throws -> Client {
        guard !host.isEmpty, host.count <= 253,
              !host.unicodeScalars.contains(where: { Py.isPySpace($0) }) else {
            throw OtaError("Enter the device management address")
        }
        var h = host
        var port = 22
        if let colon = host.firstIndex(of: ":"),
           colon != host.startIndex,
           host[host.index(after: colon)...].allSatisfy({ $0.isNumber }),
           host[host.index(after: colon)...].count <= 5,
           host.filter({ $0 == ":" }).count == 1 {
            h = String(host[..<colon])
            port = Int(host[host.index(after: colon)...]) ?? 22
        } else if host.hasPrefix("["), let close = host.firstIndex(of: "]"),
                  host.index(after: close) < host.endIndex,
                  host[host.index(after: close)] == ":" {
            h = String(host[host.index(after: host.startIndex)..<close])
            port = Int(host[host.index(after: host.index(after: close))...]) ?? 22
        }
        let authDelegate = SimplePasswordDelegate(username: "root", password: password)
        let serverDelegate = RecordingServerAuthDelegate()
        let config = SSHClientConfiguration(userAuthDelegate: authDelegate, serverAuthDelegate: serverDelegate)
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(15))
            .channelInitializer { channel in
                channel.pipeline.addHandler(NIOSSHHandler(role: .client(config), allocator: channel.allocator, inboundChildChannelInitializer: { childChannel, channelType in
                    childChannel.eventLoop.makeSucceededFuture(())
                }))
            }
        let channel: Channel
        do {
            channel = try bootstrap.connect(host: h, port: port).wait()
        } catch {
            throw OtaError(sshErrorMessage(error))
        }
        guard let sshHandler = try? channel.pipeline.handler(type: NIOSSHHandler.self).wait() else {
            _ = channel.close()
            throw OtaError("SSH handshake failed")
        }
        // Authentication runs inside the handshake; a failed auth
        // closes the channel, and the first exec channel creation
        // surfaces the failure (mapped to "Authentication failed" in
        // execute()/upload()). A still-active channel here means the
        // handshake is progressing or done.
        guard channel.isActive else {
            _ = channel.close()
            throw OtaError("Authentication failed")
        }
        return Client(channel: channel, sshHandler: sshHandler, hostKeySha256: serverDelegate.fingerprint)
    }

    private func sshErrorMessage(_ error: Error) -> String {
        let s = String(describing: error)
        if s.contains("password") || s.contains("auth") { return "Authentication failed" }
        return s
    }

    // MARK: - Exec channels

    /// Collects stdout/stderr and the exit status of one exec channel.
    private final class ExecHandler: ChannelDuplexHandler {
        typealias InboundIn = SSHChannelData
        typealias InboundOut = SSHChannelData
        typealias OutboundIn = SSHChannelData
        typealias OutboundOut = SSHChannelData

        let command: String
        let promise: EventLoopPromise<(Int, Data, Data)>
        private var stdout = Data()
        private var stderr = Data()
        private var exitStatus: Int?
        private var finished = false

        init(command: String, promise: EventLoopPromise<(Int, Data, Data)>) {
            self.command = command
            self.promise = promise
        }

        func handlerAdded(context: ChannelHandlerContext) {
            context.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let sshData = unwrapInboundIn(data)
            guard case .byteBuffer(var buffer) = sshData.data else { return }
            let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
            if sshData.type == .channel {
                stdout.append(contentsOf: bytes)
            } else if sshData.type == .stdErr {
                stderr.append(contentsOf: bytes)
            }
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if let exit = event as? SSHChannelRequestEvent.ExitStatus {
                exitStatus = exit.exitStatus
                finish(context: context)
            } else {
                context.fireUserInboundEventTriggered(event)
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            finish(context: context)
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            if !finished {
                finished = true
                promise.fail(error)
            }
            context.close(promise: nil)
        }

        private func finish(context: ChannelHandlerContext) {
            guard !finished else { return }
            finished = true
            promise.succeed((exitStatus ?? -1, stdout, stderr))
        }
    }

    /// Runs a command; raises with combined stdout+stderr on non-zero
    /// exit, like Java's execute().
    public static func execute(client: Client, command: String, timeoutSec: TimeInterval = 1800) throws -> String {
        let loop = client.channel.eventLoop
        let promise = loop.makePromise(of: (Int, Data, Data).self)
        let handler = ExecHandler(command: command, promise: promise)
        let channelPromise = loop.makePromise(of: Channel.self)
        client.sshHandler.createChannel(channelPromise, channelType: .session) { child, _ in
            child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                child.pipeline.addHandler(handler)
            }
        }
        var timeoutTask: Scheduled<Void>?
        timeoutTask = loop.scheduleTask(in: .seconds(Int64(timeoutSec))) {
            promise.fail(OtaError("Device update is still running; reconnect and check status"))
        }
        promise.futureResult.whenComplete { _ in timeoutTask?.cancel() }
        channelPromise.futureResult.whenFailure { error in
            promise.fail(Self.authMappedError(client: client, error: error))
        }
        let (code, out, err): (Int, Data, Data)
        do {
            (code, out, err) = try promise.futureResult.wait()
        } catch {
            throw error as? OtaError ?? OtaError(String(describing: error))
        }
        if out.count + err.count > 32 << 20 {
            throw OtaError("Device response exceeded limit")
        }
        let so = Py.decodeUtf8Replace([UInt8](out))
        if code != 0 {
            throw OtaError(so + Py.decodeUtf8Replace([UInt8](err)))
        }
        return so
    }

    /// A dead channel at exec time almost always means authentication
    /// failed (NIOSSH closes the connection on auth failure).
    private static func authMappedError(client: Client, error: Error) -> Error {
        if !client.channel.isActive {
            return OtaError("Authentication failed")
        }
        return error
    }

    public typealias UploadProgress = (Int64) -> Void

    /// exec `command` with `data` on stdin then EOF; returns the exit status.
    static func upload(client: Client, command: String, data: Data, progress: UploadProgress? = nil) throws -> Int {
        let loop = client.channel.eventLoop
        let promise = loop.makePromise(of: (Int, Data, Data).self)
        let handler = ExecHandler(command: command, promise: promise)
        let channelPromise = loop.makePromise(of: Channel.self)
        client.sshHandler.createChannel(channelPromise, channelType: .session) { child, _ in
            child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                child.pipeline.addHandler(handler)
            }
        }
        channelPromise.futureResult.whenComplete { result in
            switch result {
            case .success(let child):
                // Feed stdin in 128 KiB chunks, then half-close.
                var offset = 0
                var writeFuture: EventLoopFuture<Void> = child.eventLoop.makeSucceededFuture(())
                while offset < data.count {
                    let end = min(data.count, offset + (128 << 10))
                    let chunk = data[offset..<end]
                    let buffer: ByteBuffer = {
                        var b = child.allocator.buffer(capacity: chunk.count)
                        b.writeBytes(chunk)
                        return b
                    }()
                    let currentOffset = offset
                    writeFuture = writeFuture.flatMap {
                        child.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).map {
                            progress?(Int64(currentOffset + chunk.count))
                        }
                    }
                    offset = end
                }
                writeFuture.flatMap { child.close(mode: .output) }.whenFailure { error in
                    promise.fail(Self.authMappedError(client: client, error: error))
                }
            case .failure(let error):
                promise.fail(Self.authMappedError(client: client, error: error))
            }
        }
        let (code, _, _): (Int, Data, Data)
        do {
            (code, _, _) = try promise.futureResult.wait()
        } catch {
            throw error as? OtaError ?? OtaError(String(describing: error))
        }
        return code
    }

    /// exec `command` with a file on stdin then EOF; returns the exit
    /// status. The file is streamed from disk in 128 KiB chunks on a
    /// background queue (writes are thread-safe on NIO channels), so
    /// a large patch is never buffered in memory.
    static func uploadFile(client: Client, command: String, fileURL: URL, total: Int64, progress: UploadProgress? = nil) throws -> Int {
        let loop = client.channel.eventLoop
        let promise = loop.makePromise(of: (Int, Data, Data).self)
        let handler = ExecHandler(command: command, promise: promise)
        let channelPromise = loop.makePromise(of: Channel.self)
        client.sshHandler.createChannel(channelPromise, channelType: .session) { child, _ in
            child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                child.pipeline.addHandler(handler)
            }
        }
        channelPromise.futureResult.whenComplete { result in
            switch result {
            case .success(let child):
                // Start streaming only after the exec request is
                // queued (handlerAdded), so stdin never precedes it.
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let handle = try FileHandle(forReadingFrom: fileURL)
                        defer { try? handle.close() }
                        var sent: Int64 = 0
                        while sent < total {
                            guard let chunk = try handle.read(upToCount: 128 << 10), !chunk.isEmpty else { break }
                            var buffer = child.allocator.buffer(capacity: chunk.count)
                            buffer.writeBytes(chunk)
                            try child.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).wait()
                            sent += Int64(chunk.count)
                            progress?(sent)
                        }
                        _ = child.close(mode: .output)
                    } catch {
                        promise.fail(error)
                    }
                }
            case .failure(let error):
                promise.fail(Self.authMappedError(client: client, error: error))
            }
        }
        let (code, _, _): (Int, Data, Data)
        do {
            (code, _, _) = try promise.futureResult.wait()
        } catch {
            throw error as? OtaError ?? OtaError(String(describing: error))
        }
        return code
    }

    // MARK: - Protocol

    static func q(_ s: String) -> String { Py.shlexQuote(s) }

    public func remotePrepare(client: Client, archive: URL) throws -> JsonObject {
        let patch = try Ota.Patch(url: archive)
        defer { try? patch.close() }
        guard Json.truthy(patch.manifest["runtime"]) else {
            throw OtaError("This patch does not contain a portable updater runtime")
        }
        let runtime = "/tmp/unisoc-ota-" + tokenHex(32)
        _ = try Self.execute(client: client, command: "umask 077; mkdir " + Self.q(runtime))
        let bb = Self.q(runtime + "/busybox")
        for (key, file) in [("busybox", "busybox"), ("bootstrap", "bootstrap.sh")] {
            guard let desc = Json.map(patch.manifest[key]),
                  let sha = desc["sha256"], case .string(let shaStr) = sha else {
                throw OtaError("Invalid \(key) payload")
            }
            let content = try patch.blob(shaStr)
            let cat = key == "busybox" ? "cat" : bb + " cat"
            let code = try Self.upload(client: client,
                                       command: "umask 077; " + cat + " > " + Self.q(runtime + "/" + file),
                                       data: content)
            guard code == 0 else { throw OtaError("Runtime helper upload failed") }
            if key == "busybox" {
                _ = try Self.execute(client: client, command: "chmod 700 " + Self.q(runtime + "/busybox"))
            }
            let got = try Self.first(Self.execute(client: client, command: bb + " sha256sum " + Self.q(runtime + "/" + file)))
            guard got == shaStr else { throw OtaError("Runtime helper checksum mismatch") }
        }
        let available = Set(Py.splitlines(try Self.execute(client: client, command: bb + " --list")))
        let required = ["sh", "cat", "chmod", "mkdir", "df", "sha256sum", "mv", "unzip", "cp", "ln", "rm", "mount", "chroot", "reboot"]
        let missing = required.filter { !available.contains($0) }.sorted()
        guard missing.isEmpty else {
            throw OtaError("Packaged updater BusyBox lacks: " + missing.joined(separator: ", "))
        }
        let destination = "/etc/unisoc-ota/upload-" + patch.id + ".ota"
        let total = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? 0
        let dfLines = Py.splitlines(try Self.execute(client: client, command: bb + " df -Pk /etc"))
        guard let lastLine = dfLines.last else {
            throw OtaError("invalid literal for int() with base 10: ''")
        }
        let cols = Py.splitWhitespace(lastLine)
        let free: Int64
        if cols.count >= 3, let v = Int64(cols[cols.count - 3]) {
            free = v * 1024
        } else {
            throw OtaError("invalid literal for int() with base 10: " + Py.repr(cols.isEmpty ? "" : cols[max(0, cols.count - 3)]))
        }
        guard total + (32 << 20) <= free else {
            throw OtaError("Insufficient device staging space")
        }
        _ = try Self.execute(client: client, command: "umask 077; " + bb + " mkdir -p /etc/unisoc-ota")
        guard let archiveStream = InputStream(url: archive) else {
            throw OtaError("Cannot open \(archive.lastPathComponent)")
        }
        archiveStream.open()
        defer { archiveStream.close() }
        let expected = try Py.digest(archiveStream)
        var lastReport = DispatchTime.now().uptimeNanoseconds
        let code = try Self.uploadFile(client: client,
                                       command: "umask 077; " + bb + " cat > " + Self.q(destination + ".new"),
                                       fileURL: archive, total: total) { done in
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastReport > 200_000_000 || done == total {
                lastReport = now
                var d = JsonObject()
                d.put("stage", .string("upload"))
                d.put("done", .int(done))
                d.put("total", .int(total))
                self.events(d)
            }
        }
        guard code == 0 else { throw OtaError("Device upload failed") }
        let got = try Self.first(Self.execute(client: client, command: bb + " sha256sum " + Self.q(destination + ".new")))
        guard got == expected else { throw OtaError("Device upload checksum mismatch") }
        _ = try Self.execute(client: client, command: bb + " mv " + Self.q(destination + ".new") + " " + Self.q(destination))
        var r = JsonObject()
        r.put("path", .string(destination))
        r.put("runtime", .string(runtime))
        return r
    }

    private static func first(_ s: String) throws -> String {
        let p = Py.splitWhitespace(s)
        guard let first = p.first else {
            throw OtaError("IndexError: list index out of range")
        }
        return first
    }

    public static func runtimeCall(client: Client, session: JsonObject, command: String, setup: Bool) throws -> JsonObject {
        guard case .string(let home) = session["runtime"] else {
            throw OtaError("Unexpected device response")
        }
        let shell: String
        if setup, command == "start" {
            shell = try runtimeStartCommand(session)
        } else if setup {
            guard case .string(let path) = session["path"] else {
                throw OtaError("Unexpected device response")
            }
            shell = [q(home + "/busybox"), "sh", q(home + "/bootstrap.sh"), q(path), q(command), q(home)].joined(separator: " ")
        } else {
            shell = "UNISOC_OTA_ROOT=/target UNISOC_OTA_RAM=/ UNISOC_OTA_LIVE=1 PYTHONHOME=/usr " + q(home + "/busybox") + " chroot "
                + q(home + "/root") + " /usr/bin/python3 /ota/rpc.py " + q(command)
        }
        guard let m = Json.map(try Json.parse(Self.execute(client: client, command: shell))) else {
            throw OtaError("Unexpected device response")
        }
        return m
    }

    /// The bootstrap helper derives its start ID from home; this home
    /// is intentionally random. Re-run the read-only bootstrap
    /// inspection, then pass the reviewed patch ID directly to RPC.
    static func runtimeStartCommand(_ session: JsonObject) throws -> String {
        guard case .string(let home) = session["runtime"],
              case .string(let path) = session["path"] else {
            throw OtaError("Patch review ID is missing; inspect the patch again")
        }
        let check = Json.map(session["check"])
        guard let reviewed = check?["id"], Ota.isHex(reviewed),
              case .string(let reviewedStr) = reviewed else {
            throw OtaError("Patch review ID is missing; inspect the patch again")
        }
        let inspect = [q(home + "/busybox"), "sh", q(home + "/bootstrap.sh"), q(path), "inspect", q(home)].joined(separator: " ")
        return inspect + " >/dev/null && printf '%s\\n' " + q(home + "/root")
            + " > /etc/unisoc-ota/active-runtime && UNISOC_OTA_ROOT=/target UNISOC_OTA_RAM=/ UNISOC_OTA_LIVE=1 PYTHONHOME=/usr "
            + q(home + "/busybox") + " chroot " + q(home + "/root")
            + " /usr/bin/python3 /ota/rpc.py start " + q("/target" + path) + " " + q(reviewedStr)
    }

    func remoteInspect(client: Client, archive: URL) throws -> JsonObject {
        var session = try remotePrepare(client: client, archive: archive)
        let check = try Self.runtimeCall(client: client, session: session, command: "inspect", setup: true)
        session.put("check", .object(check))
        return session
    }

    static func refreshRpc(client: Client) throws -> JsonObject {
        _ = try execute(client: client, command: "/etc/init.d/rpcd reload", timeoutSec: 15)
        let deadline = DispatchTime.now() + .seconds(5)
        while true {
            do {
                guard let value = Json.map(try Json.parse(Self.execute(client: client, command: "ubus call unisoc-ota status", timeoutSec: 3))),
                      value.contains("identity"), !Json.truthy(value["error"]) else {
                    throw OtaError("still registering")
                }
                var r = JsonObject()
                r.put("status", .string("ready"))
                return r
            } catch let e as OtaError where e.message == "still registering" {
                // Still registering; keep polling.
            } catch {
                // RuntimeError / ValueError: still registering.
            }
            guard DispatchTime.now() < deadline else {
                throw OtaError("unisoc-ota RPC did not register after reload")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    // MARK: - Commands (Desktop.dispatch)

    /// ota_probe
    public func probe(host: String, password: String, path: URL?) throws -> JsonObject {
        lock.lock()
        review = nil
        lock.unlock()
        let archive = path ?? archivePath ?? root.appendingPathComponent("update.ota")
        lock.lock()
        archivePath = archive
        lock.unlock()
        let client = try connect(host: host, password: password)
        defer { client.close() }
        let result = try remoteInspect(client: client, archive: archive)
        let key = client.hostKeySha256
        let token = tokenHex(24)
        var rv = JsonObject()
        rv.put("host", .string(host))
        rv.put("key", .string(key))
        rv.put("token", .string(token))
        for (k, v) in result.pairs { rv.put(k, v) }
        lock.lock()
        review = rv
        var rs = JsonObject()
        rs.put("host", .string(host))
        rs.put("key", .string(key))
        for (k, v) in result.pairs { rs.put(k, v) }
        runtimeSession = rs
        lock.unlock()
        var out = JsonObject()
        out.put("token", .string(token))
        for (k, v) in result.pairs { out.put(k, v) }
        return out
    }

    /// ota_apply
    public func apply(host: String, password: String, token: String?, autoReboot: Bool) throws -> JsonObject {
        lock.lock()
        let r = review
        lock.unlock()
        guard let r, let token,
              case .string(let reviewToken) = r["token"], token == reviewToken,
              case .string(let reviewHost) = r["host"], host == reviewHost else {
            throw OtaError("Review this device and patch before applying")
        }
        let client = try connect(host: host, password: password)
        defer { client.close() }
        let key = client.hostKeySha256
        guard case .string(let reviewKey) = r["key"], key == reviewKey else {
            throw OtaError("Device SSH identity changed since review")
        }
        let result = try Self.runtimeCall(client: client, session: r, command: "start", setup: true)
        lock.lock()
        runtimeSession = r
        if autoReboot {
            var p = JsonObject()
            p.put("host", r["host"] ?? .null)
            p.put("key", r["key"] ?? .null)
            p.put("id", Json.map(r["check"])?["id"] ?? .null)
            pendingReboot = p
        } else {
            pendingReboot = nil
        }
        review = nil
        lock.unlock()
        return result
    }

    /// ota_reboot
    public func reboot(host: String, password: String) throws -> JsonObject {
        let client = try connect(host: host, password: password)
        defer { client.close() }
        let key = client.hostKeySha256
        lock.lock()
        let session = runtimeSession
        lock.unlock()
        guard let session,
              case .string(let sessionHost) = session["host"], host == sessionHost,
              case .string(let sessionKey) = session["key"], key == sessionKey else {
            throw OtaError("Check this device before rebooting")
        }
        let status = try Self.runtimeCall(client: client, session: session, command: "status", setup: false)
        let job = Json.map(status["job"])
        let tx = Json.map(status["transaction"])
        let txs = tx.flatMap { Json.str($0["status"]) }
        if (job.flatMap { Json.str($0["status"]) } == "running") || txs == "applying" || txs == "rolling_back" {
            throw OtaError("The device is still updating; do not reboot")
        }
        lock.lock()
        pendingReboot = nil
        lock.unlock()
        return try Self.runtimeCall(client: client, session: session, command: "reboot", setup: false)
    }

    /// ota_status
    public func status(host: String, password: String, path: URL?) throws -> JsonObject {
        let client = try connect(host: host, password: password)
        defer { client.close() }
        let key = client.hostKeySha256
        lock.lock()
        var session = runtimeSession
        lock.unlock()
        var setup = session == nil
            || (Json.str(session?["host"]) != host)
            || (Json.str(session?["key"]) != key)
        if !setup, let session {
            guard case .string(let home) = session["runtime"] else {
                throw OtaError("Unexpected device response")
            }
            let ready = Py.strip(try Self.execute(client: client, command: "if test -x " + Self.q(home + "/busybox") + " && test -x " + Self.q(home + "/root/usr/bin/python3")
                + " && test -d " + Self.q(home + "/root/target/etc") + "; then echo ready; fi"))
            setup = ready != "ready"
        }
        if setup {
            let archive = path ?? archivePath ?? root.appendingPathComponent("update.ota")
            guard FileManager.default.isReadableFile(atPath: archive.path) else {
                throw OtaError("Select the OTA patch before checking this old device")
            }
            var s = JsonObject()
            s.put("host", .string(host))
            s.put("key", .string(key))
            let prepared = try remotePrepare(client: client, archive: archive)
            for (k, v) in prepared.pairs { s.put(k, v) }
            session = s
        }
        guard let session else {
            throw OtaError("Unexpected device response")
        }
        var result = try Self.runtimeCall(client: client, session: session, command: "status", setup: setup)
        lock.lock()
        runtimeSession = session
        lock.unlock()
        let transaction = Json.map(result["transaction"]) ?? JsonObject()
        let job = Json.map(result["job"]) ?? JsonObject()
        let txStatus = Json.str(transaction["status"])
        if Json.str(job["status"]) == "complete" && (txStatus == "complete" || txStatus == "rolled_back") {
            let txId = Json.str(transaction["id"]) ?? ""
            let marker = host + "\0" + key + "\0" + txId + "\0" + (txStatus ?? "")
            let jr = Json.map(job["result"])
            var activation = jr.flatMap { Json.map($0["activation"]) } ?? JsonObject()
            if activated.contains(marker) {
                activation = JsonObject()
                activation.put("status", .string("ready"))
            }
            if !activated.contains(marker), Json.str(activation["status"]) != "ready" {
                do {
                    activation = try Self.refreshRpc(client: client)
                } catch {
                    activation = JsonObject()
                    activation.put("status", .string("warning"))
                    activation.put("error", .string(String(describing: error)))
                }
            }
            if Json.str(activation["status"]) == "ready" {
                lock.lock()
                activated.insert(marker)
                lock.unlock()
            }
            result.put("activation", .object(activation))
            lock.lock()
            let pending = pendingReboot
            lock.unlock()
            if let pending,
               Json.str(pending["host"]) == host, Json.str(pending["key"]) == key,
               Json.pyEquals(pending["id"], transaction["id"]) {
                lock.lock()
                pendingReboot = nil
                lock.unlock()
                do {
                    result.put("reboot", .object(try Self.runtimeCall(client: client, session: session, command: "reboot", setup: false)))
                } catch {
                    var f = JsonObject()
                    f.put("status", .string("failed"))
                    f.put("error", .string(String(describing: error)))
                    result.put("reboot", .object(f))
                }
            }
        } else if Json.str(job["status"]) == "failed" {
            lock.lock()
            pendingReboot = nil
            lock.unlock()
        }
        return result
    }

    /// Selecting a new patch invalidates any earlier review (ota_package).
    public func selectPatch(_ archive: URL) {
        lock.lock()
        archivePath = archive
        review = nil
        lock.unlock()
    }
}
