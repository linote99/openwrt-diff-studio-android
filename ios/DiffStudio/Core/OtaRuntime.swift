// OtaRuntime.swift
// Port of com.linote.diffstudio.core.OtaRuntime (Java, MIT).
// Port of ota_runtime.py.

import Foundation

public enum OtaRuntime {
    /// Ordered support sources: engine.py, boot.py, rpc.py, proxy.sh,
    /// unisoc-ota.js, errors.js, unisoc-ota.json, lz4raw-aarch64.so
    public protocol SupportFiles {
        /// family is "e5" or "mu300": each desktop edition ships its
        /// own protocol engine.
        func read(family: String, name: String) throws -> Data
    }

    public static let TEXT_SUPPORT = ["engine.py", "boot.py", "rpc.py", "proxy.sh", "unisoc-ota.js", "errors.js", "unisoc-ota.json"]

    public static func supportSources(family: String, files: SupportFiles) throws -> OrderedMap<String, Data> {
        var result = OrderedMap<String, Data>()
        for name in TEXT_SUPPORT {
            result.put(name, crlfToLf(try files.read(family: family, name: name)))
        }
        result.put("lz4raw-aarch64.so", try files.read(family: family, name: "lz4raw-aarch64.so"))
        return result
    }

    static func crlfToLf(_ b: Data) -> Data {
        var out = Data()
        out.reserveCapacity(b.count)
        var prev: UInt8 = 0
        for byte in b {
            if byte == 0x0A, prev == 0x0D {
                // Drop the CR that precedes this LF.
                out.removeLast()
            }
            out.append(byte)
            prev = byte
        }
        return out
    }

    public struct Built {
        public let runtime: OrderedMap<String, JsonObject>
        public let busybox: JsonObject? // nil when the release has no static BusyBox
        public let extra: OrderedMap<String, Data>

        public init(runtime: OrderedMap<String, JsonObject>, busybox: JsonObject?, extra: OrderedMap<String, Data>) {
            self.runtime = runtime
            self.busybox = busybox
            self.extra = extra
        }
    }

    private static func selected(_ name: String) -> Bool {
        if name.hasPrefix("usr/lib/python3") || name.hasPrefix("usr/bin/python3") { return true }
        guard name.hasPrefix("lib/") || name.hasPrefix("usr/lib/") else { return false }
        let parts = name.split(separator: "/", maxSplits: name.hasPrefix("usr/") ? 2 : 1, omittingEmptySubsequences: false)
        guard let last = parts.last, !last.contains("/") else { return false }
        return name.contains(".so") || name.hasSuffix("/libc.so")
    }

    public static func build(_ release: Release, files: SupportFiles) throws -> Built {
        var runtime = OrderedMap<String, JsonObject>()
        var extra = OrderedMap<String, Data>()
        for (name, desc) in release.entries.pairs {
            if selected(name), desc["kind"] != .string("dir") {
                runtime.put(name, desc)
            }
        }
        for _ in 0..<8 {
            var added = false
            for (name, desc) in runtime.pairs {
                guard desc["kind"] == .string("symlink"),
                      let targetVal = desc["target"], case .string(let targetRaw) = targetVal else { continue }
                let target = Py.normpath(targetRaw.hasPrefix("/") ? String(targetRaw.drop(while: { $0 == "/" })) : Py.join(Py.dirname(name), targetRaw))
                if !runtime.contains(target), release.entries.contains(target) {
                    runtime.put(target, release.entries[target]!)
                    added = true
                }
            }
            if !added { break }
        }
        for (name, content) in try supportSources(family: release.family, files: files).pairs {
            let h = Py.sha256Hex(content)
            extra.put(h, content)
            runtime.put("ota/" + name, fileDesc(mode: 0o644, size: Int64(content.count), sha: h))
        }
        var busyboxName: String?
        for n in ["files/busybox", "payload/busybox", "busybox"] where release.exists(n) {
            busyboxName = n
            break
        }
        var bb: JsonObject?
        if let busyboxName {
            let stream = try release.open(busyboxName)
            stream.open()
            defer { stream.close() }
            let content = try Py.readUpTo(stream, limit: 16 << 20)
            let h = Py.sha256Hex(content)
            extra.put(h, content)
            var b = JsonObject()
            b.put("sha256", .string(h))
            b.put("size", .int(Int64(content.count)))
            bb = b
            runtime.put("ota/busybox", fileDesc(mode: 0o700, size: Int64(content.count), sha: h))
        }
        return Built(runtime: runtime, busybox: bb, extra: extra)
    }

    static func fileDesc(mode: Int64, size: Int64, sha: String) -> JsonObject {
        var d = JsonObject()
        d.put("kind", .string("file"))
        d.put("mode", .int(mode))
        d.put("uid", .int(0))
        d.put("gid", .int(0))
        d.put("xattrs", .object(JsonObject()))
        d.put("size", .int(size))
        d.put("sha256", .string(sha))
        return d
    }

    /// str(Path(name).parent).replace('\\', '/') as evaluated on
    /// Windows for the generated relative names.
    static func parent(_ name: String) -> String {
        guard let i = name.lastIndex(of: "/") else { return "." }
        return String(name[..<i])
    }

    public static func bootstrap(_ runtime: OrderedMap<String, JsonObject>) -> Data {
        var lines: [String] = [
            "#!/bin/sh", "set -eu", "umask 077", "patch=$1", "command=$2", "home=$3",
            "session=${home#/tmp/unisoc-ota-}",
            "case \"$session\" in *[!0-9a-f]*|'') exit 2 ;; esac",
            "[ \"$home\" != \"$session\" ] && [ ${#session} -eq 64 ] && [ ! -L \"$home\" ]",
            "id=${4:-}",
            "if [ -z \"$id\" ]; then",
            " id=${patch##*/}",
            " case \"$id\" in upload-*.ota) id=${id#upload-}; id=${id%.ota} ;; reviewed-*.ota) id=${id#reviewed-}; id=${id%.ota} ;; *) id= ;; esac",
            "fi",
            "if [ \"$command\" = start ]; then",
            " case \"$id\" in *[!0-9a-f]*|'') exit 2 ;; esac",
            " [ ${#id} -eq 64 ]",
            "fi",
            "bb=\"$home/busybox\"", "root=\"$home/root\"", "\"$bb\" mkdir -p \"$root\" \"$home/content\"",
            "mounted() {",
            " while read -r source destination rest; do",
            "  [ \"$destination\" != \"$1\" ] || return 0",
            " done < /proc/mounts",
            " return 1", "}",
        ]
        var hashes = Set<String>()
        for d in runtime.values where d["kind"] == .string("file") {
            if case .string(let h) = d["sha256"] { hashes.insert(h) }
        }
        let sortedHashes = hashes.sorted { Py.codepointCompare($0, $1) == .orderedAscending }
        var unzip = "\"$bb\" unzip -oq \"$patch\" "
        unzip += sortedHashes.map { "blobs/" + $0 }.joined(separator: " ")
        unzip += " -d \"$home/content\""
        lines.append(unzip)
        lines.append("\"$bb\" cat > \"$home/runtime.sha256\" <<'OTA_RUNTIME_HASHES'")
        for h in sortedHashes { lines.append(h + "  content/blobs/" + h) }
        lines.append("OTA_RUNTIME_HASHES")
        lines.append("(cd \"$home\"; \"$bb\" sha256sum -c runtime.sha256 >/dev/null)")
        let sorted = runtime.pairs.sorted { Py.codepointCompare($0.0, $1.0) == .orderedAscending }
        for (name, desc) in sorted {
            let path = "\"$root\"/" + Py.shlexQuote(name)
            lines.append("\"$bb\" mkdir -p \"$root\"/" + Py.shlexQuote(parent(name)))
            if desc["kind"] == .string("file") {
                guard case .string(let sha) = desc["sha256"], let modeValue = desc["mode"] else { continue }
                lines.append("\"$bb\" cp \"$home/content/blobs/" + sha + "\" " + path + ".new")
                lines.append("\"$bb\" chmod " + Py.oct(Json.asLong(modeValue)) + " " + path + ".new")
                lines.append("\"$bb\" mv " + path + ".new " + path)
            } else {
                guard case .string(let target) = desc["target"] else { continue }
                lines.append("\"$bb\" ln -snf " + Py.shlexQuote(target) + " " + path)
            }
        }
        lines += [
            "\"$bb\" rm -rf \"$home/content\"",
            "\"$bb\" mkdir -p \"$root/target\" \"$root/dev\" \"$root/proc\" \"$root/sys\" \"$root/target/dev\" \"$root/target/run\" \"$root/target/sys\"",
            "mounted \"$root/target\" || \"$bb\" mount --bind / \"$root/target\"",
            "mounted \"$root/dev\" || \"$bb\" mount --bind /dev \"$root/dev\"",
            "mounted \"$root/target/dev\" || \"$bb\" mount --bind /dev \"$root/target/dev\"",
            "mounted \"$root/target/run\" || \"$bb\" mount --bind /run \"$root/target/run\"",
            "mounted \"$root/sys\" || \"$bb\" mount --bind /sys \"$root/sys\"",
            "mounted \"$root/target/sys\" || \"$bb\" mount --bind /sys \"$root/target/sys\"",
            "mounted \"$root/proc\" || \"$bb\" mount -t proc proc \"$root/proc\"",
            "if [ \"$command\" = start ]; then printf \"%s\\n\" \"$root\" > /etc/unisoc-ota/active-runtime; fi",
            "export UNISOC_OTA_ROOT=/target UNISOC_OTA_RAM=/ UNISOC_OTA_LIVE=1 PYTHONHOME=/usr",
            "case \"$command\" in",
            " inspect) exec \"$bb\" chroot \"$root\" /usr/bin/python3 /ota/engine.py inspect \"/target$patch\" --root /target ;;",
            " start) exec \"$bb\" chroot \"$root\" /usr/bin/python3 /ota/rpc.py start \"/target$patch\" \"$id\" ;;",
            " status) exec \"$bb\" chroot \"$root\" /usr/bin/python3 /ota/rpc.py status ;;",
            " *) exit 2 ;;", "esac",
        ]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
