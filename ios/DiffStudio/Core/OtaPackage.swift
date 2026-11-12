// OtaPackage.swift
// Port of com.linote.diffstudio.core.OtaPackage (Java, MIT).
// Port of ota_package.compare / analyze / patch_filename.

import Foundation

public enum OtaPackage {
    public struct Analysis {
        public var manifest: JsonObject = JsonObject()
        public var blockers: [String] = []
        public var canExport = false
        public var suggestedName = ""
        public var payloadBytes: Int64 = 0
        public var files = 0
        public var added = 0
        public var removed = 0
        public var output: URL?
        public var archiveBytes: Int64 = 0
        /// The new release's version index, saved after a successful compatible analysis.
        public var indexPath: URL?
        var extra: OrderedMap<String, Data> = OrderedMap()
    }

    private static let unsafePattern = "[<>:\"/\\\\|?*\\x00-\\x1f\\x7f]"

    static func safe(_ text: String, limit: Int) -> String {
        var t = text.replacingOccurrences(of: unsafePattern, with: "_", options: .regularExpression)
        t = Py.rstripChars(Py.strip(t), ". ")
        var bytes = [UInt8](t.utf8)
        if bytes.count > limit {
            var n = limit
            while n > 0, (bytes[n] & 0xC0) == 0x80 { n -= 1 }
            bytes = Array(bytes[0..<n])
            t = String(bytes: bytes, encoding: .utf8) ?? ""
        }
        return Py.rstripChars(t, ". ")
    }

    private static let datePattern = "(?:^|-)r?(\\d{8}(?:\\.\\d{6})?)(?=-|$)"
    private static let commitPattern = "(?:^|-)g([a-fA-F0-9]{7,64})(?=-|$)"
    private static let kernelPattern = "^\\d+(?:\\.\\d+){1,3}"

    private static func marker(_ meta: JsonObject) -> String? {
        guard case .string(let version) = meta["image_version"],
              let dateCap = firstCapture(version, pattern: datePattern),
              let commitCap = firstCapture(version, pattern: commitPattern) else { return nil }
        return dateCap + "-g" + String(commitCap.prefix(8)).lowercased()
    }

    private static func firstCapture(_ s: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func findPrefix(_ s: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range, in: s) else { return nil }
        return String(s[r])
    }

    public static func patchFilename(old: JsonObject, neu: JsonObject, source: String) -> String {
        guard let start = marker(old), let end = marker(neu) else {
            var leaf = source.replacingOccurrences(of: "\\", with: "/")
            if let i = leaf.lastIndex(of: "/") { leaf = String(leaf[leaf.index(after: i)...]) }
            var stem = leaf.lowercased().hasSuffix(".zip") ? String(leaf.dropLast(4)) : leaf
            stem = safe(stem, limit: 180)
            return "OpenWrt-patch" + (stem.isEmpty ? "" : "-" + stem) + ".zip"
        }
        let models: [String: String] = [
            "e5": "E5", "t551m": "T551M", "t512n": "T512N", "m8": "M8",
            "lym10k": "LYM-10K", "yuanhang41s": "Yuanhang41S", "k1": "K1",
            "u30air": "U30Air", "mu300": "MU300-F50-V50-U30Air", "u30pro": "U30Pro",
            "f50pro": "F50Pro", "f50": "F50", "v50": "V50",
        ]
        let profile: String = {
            if case .string(let s) = neu["profile"] { return s }
            return ""
        }()
        var model = models[profile] ?? safe(profile, limit: 32)
        if model.isEmpty { model = "Device" }
        var version = safe({
            if case .string(let s) = neu["openwrt"] { return s }
            return ""
        }(), limit: 24)
        let previous = safe({
            if case .string(let s) = old["openwrt"] { return s }
            return ""
        }(), limit: 24)
        if !previous.isEmpty, !version.isEmpty, previous != version {
            version = previous + "-to-" + version
        }
        let kernel: String = {
            if case .string(let s) = neu["kernel_release"] { return s }
            return ""
        }()
        var parts = ["OpenWrt", "patch", model]
        if !version.isEmpty { parts.append(version) }
        if let k = findPrefix(kernel, pattern: kernelPattern) { parts.append("k" + k) }
        parts.append(start)
        parts.append("to")
        parts.append(end)
        return safe(parts.joined(separator: "-"), limit: 220) + ".zip"
    }

    private static func dirDesc() -> JsonObject {
        var d = JsonObject()
        d.put("kind", .string("dir"))
        d.put("mode", .int(0o755))
        d.put("uid", .int(0))
        d.put("gid", .int(0))
        d.put("xattrs", .object(JsonObject()))
        return d
    }

    public static func compare(old: ReleaseIndex.Base, neu: Release, support: OtaRuntime.SupportFiles) throws -> Analysis {
        guard old.family == neu.family else {
            throw OtaError("Packages belong to different device families")
        }
        guard Json.pyEquals(old.meta["profile"], neu.meta["profile"]) else {
            throw OtaError("Incompatible full releases: profile")
        }
        let built = try OtaRuntime.build(neu, files: support)
        let runtime = built.runtime
        let busybox = built.busybox
        let supportBlobs = built.extra
        let portable = busybox != nil && runtime.contains("usr/bin/python3")
        if portable {
            for name in ["engine.py", "boot.py", "rpc.py", "proxy.sh"] {
                if let d = runtime["ota/" + name] {
                    neu.entries.put("usr/lib/unisoc-ota/" + name, d)
                }
            }
            if var proxy = runtime["ota/proxy.sh"] {
                proxy.put("mode", .int(0o755))
                neu.entries.put("usr/libexec/rpcd/unisoc-ota", proxy)
            }
            let dests = [("unisoc-ota.js", "www/luci-static/resources/view/system/unisoc-ota.js"),
                         ("errors.js", "www/luci-static/resources/unisoc-ota/errors.js"),
                         ("unisoc-ota.json", "usr/share/rpcd/acl.d/unisoc-ota.json")]
            for (src, dest) in dests {
                if let d = runtime["ota/" + src] { neu.entries.put(dest, d) }
            }
            for name in ["usr/lib/unisoc-ota", "usr/libexec", "usr/libexec/rpcd"] where !neu.entries.contains(name) {
                neu.entries.put(name, dirDesc())
            }
        }
        var operations: [JsonValue] = []
        var preserved: [JsonValue] = []
        var blockers: [String] = []
        var all = Set<String>()
        all.formUnion(old.entries.keys)
        all.formUnion(neu.entries.keys)
        let sortedAll = all.sorted { Py.codepointCompare($0, $1) == .orderedAscending }
        for name in sortedAll {
            let before = old.entries[name]
            let after = neu.entries[name]
            if Json.pyEquals(before.map { .object($0) }, after.map { .object($0) }) { continue }
            var merge: String?
            if name == "etc/e5/release.json" || name == "etc/mu300/release.json" { merge = "release" }
            else if ["etc/passwd", "etc/shadow", "etc/group", "etc/gshadow"].contains(name) { merge = "accounts" }
            else if name == "etc/apk/world" { merge = "world" }
            else if name == "lib/apk/db/installed" { merge = "apk-db" }
            else if name == "lib/apk/db/scripts.tar" { merge = "apk-scripts" }
            else if name == "lib/apk/db/triggers" { merge = "apk-triggers" }
            else if (try Ota.isProtected(name)) {
                if name.hasPrefix("etc/"), before == nil, let after, Json.truthy(.object(after)),
                   after["kind"] != .string("dir"),
                   !(name.hasPrefix("etc/unisoc-ota/") || name.hasPrefix("etc/uci-defaults/")) {
                    merge = "default"
                } else {
                    preserved.append(.string(name))
                    continue
                }
            }
            if let before, Json.truthy(.object(before)), before["kind"] == .string("dir"),
               after == nil {
                preserved.append(.string(name))
                continue
            }
            var op = JsonObject()
            op.put("path", .string(name))
            op.put("before", before.map { .object($0) } ?? .null)
            op.put("after", after.map { .object($0) } ?? .null)
            if let merge { op.put("merge", .string(merge)) }
            operations.append(.object(op))
        }
        var m = JsonObject()
        m.put("format", .string(Ota.FORMAT))
        m.put("family", .string(neu.family))
        m.put("profile", neu.meta["profile"] ?? .null)
        m.put("base_version", old.meta["image_version"] ?? .null)
        m.put("target_version", neu.meta["image_version"] ?? .null)
        m.put("kernel_release", neu.meta["kernel_release"] ?? .null)
        m.put("operations", .array(operations))
        m.put("preserved", .array(preserved))
        m.put("mode", .string("differential"))
        m.put("base_packages", .object(Json.objectOfDescriptors(old.packages)))
        m.put("target_packages", .object(Json.objectOfDescriptors(neu.packages)))
        let oldBoot = old.bootDigest
        let bootStream = try neu.open(neu.bootName)
        bootStream.open()
        defer { bootStream.close() }
        let content = try Py.readUpTo(bootStream, limit: 128 << 20)
        let newBoot = Py.sha256Hex(content)
        var extra = OrderedMap<String, Data>()
        if oldBoot != newBoot {
            var boot = JsonObject()
            boot.put("sha256", .string(newBoot))
            boot.put("size", .int(Int64(content.count)))
            m.put("boot", .object(boot))
            extra.put(newBoot, content)
        }
        if portable {
            m.put("runtime", .object(Json.objectOfDescriptors(runtime)))
            if let busybox { m.put("busybox", .object(busybox)) }
            let script = OtaRuntime.bootstrap(runtime)
            let h = Py.sha256Hex(script)
            var bs = JsonObject()
            bs.put("sha256", .string(h))
            bs.put("size", .int(Int64(script.count)))
            m.put("bootstrap", .object(bs))
            var merged = supportBlobs
            merged.put(h, script)
            for (k, v) in merged.pairs where !extra.contains(k) {
                extra.put(k, v)
            }
        }
        do {
            _ = try Ota.validateManifest(.object(m))
        } catch let e as OtaError {
            blockers.append(e.message)
        }
        var blobs = OrderedMap<String, Int64>()
        var added = 0, removed = 0
        for oo in operations {
            guard let o = Json.map(oo) else { continue }
            if let after = Json.map(o["after"]), Json.truthy(.object(after)), after["kind"] == .string("file"),
               let sha = after["sha256"], case .string(let shaStr) = sha, let size = after["size"] {
                blobs.put(shaStr, Json.asLong(size))
            }
            if o["before"] == nil || o["before"] == .null { added += 1 }
            if o["after"] == nil || o["after"] == .null { removed += 1 }
        }
        if let rt = Json.map(m["runtime"]) {
            for d in rt.values {
                if let dm = Json.map(d), dm["kind"] == .string("file"),
                   let sha = dm["sha256"], case .string(let shaStr) = sha, let size = dm["size"] {
                    blobs.put(shaStr, Json.asLong(size))
                }
            }
        }
        for key in ["boot", "busybox", "bootstrap"] where m.contains(key) {
            if let d = Json.map(m[key]),
               let sha = d["sha256"], case .string(let shaStr) = sha, let size = d["size"] {
                blobs.put(shaStr, Json.asLong(size))
            }
        }
        var a = Analysis()
        a.manifest = m
        a.blockers = blockers
        a.canExport = blockers.isEmpty
        a.suggestedName = patchFilename(old: old.meta, neu: neu.meta, source: neu.source.displayName)
        var total: Int64 = 0
        for v in blobs.values { total += v }
        a.payloadBytes = total
        a.files = operations.count
        a.added = added
        a.removed = removed
        a.extra = extra
        return a
    }

    /// analyze(old, new, output): the old index is released before the
    /// new image is decompressed. When output is non-null the verified
    /// differential archive is written there.
    public static func analyze(oldSrc: Release.Source?, oldIndex: ReleaseIndex.Base?,
                               newSrc: Release.Source, output: URL?,
                               progress: Release.Progress?, support: OtaRuntime.SupportFiles,
                               scratch: URL, indexDirectory: URL?) throws -> Analysis {
        if newSrc.displayName.lowercased().hasSuffix(".json") {
            throw OtaError("The new release must be a full package, not a version index / 新版必须选择完整安装包，不能使用版本摘要")
        }
        let old: ReleaseIndex.Base
        if let oldIndex {
            old = oldIndex
        } else {
            guard let oldSrc else {
                throw OtaError("Select an old release or version index")
            }
            let full = try Release(source: oldSrc, scratch: scratch, progress: progress)
            try? full.close() // entries/meta/packages stay in memory; the scratch image is gone
            old = ReleaseIndex.Base.of(full)
        }
        let neu = try Release(source: newSrc, scratch: scratch, progress: progress)
        defer { try? neu.close() }
        var result = try compare(old: old, neu: neu, support: support)
        if let indexDirectory, result.canExport {
            // compare() includes the updater files actually supplied by this generator.
            result.indexPath = try ReleaseIndex.saveIndex(neu, directory: indexDirectory)
        }
        if let output {
            guard result.blockers.isEmpty else {
                throw OtaError(result.blockers.prefix(12).joined(separator: "; "))
            }
            guard !FileManager.default.fileExists(atPath: output.path) else {
                throw OtaError("Output already exists; select a new filename")
            }
            let tmp = output.appendingPathExtension("building")
            guard !FileManager.default.fileExists(atPath: tmp.path) else {
                throw OtaError("Output staging exists")
            }
            defer {
                if FileManager.default.fileExists(atPath: tmp.path) {
                    try? FileManager.default.removeItem(at: tmp)
                }
            }
            do {
                let archive = try ZipOut(url: tmp)
                var ok = false
                do {
                    try archive.writeBytes("manifest.json", Json.canonical(.object(result.manifest)))
                    var wanted = Set<String>()
                    if let ops = Json.list(result.manifest["operations"]) {
                        for oo in ops {
                            if let after = Json.map(Json.map(oo)?["after"]),
                               Json.truthy(.object(after)), after["kind"] == .string("file"),
                               let sha = after["sha256"], case .string(let shaStr) = sha {
                                wanted.insert(shaStr)
                            }
                        }
                    }
                    if let rt = Json.map(result.manifest["runtime"]) {
                        for d in rt.values {
                            if let dm = Json.map(d), dm["kind"] == .string("file"),
                               let sha = dm["sha256"], case .string(let shaStr) = sha {
                                wanted.insert(shaStr)
                            }
                        }
                    }
                    for (key, bytes) in result.extra.pairs {
                        try archive.writeBytes("blobs/" + key, bytes)
                    }
                    wanted.subtract(result.extra.keys)
                    try neu.writeBlobs(archive, wanted: wanted, progress: progress ?? { _, _ in })
                    ok = true
                } catch {
                    archive.abort()
                    throw error
                }
                if ok { try archive.close() }
                progress?("verify", output.lastPathComponent)
                _ = try Ota.Patch(url: tmp) // full re-verification of the written archive
                do {
                    try FileManager.default.moveItem(at: tmp, to: output)
                } catch {
                    throw OtaError("Cannot move finished patch into place")
                }
                result.output = output
                result.archiveBytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
            }
        }
        return result
    }

    /// Copy helper used by bundle export.
    static func copy(_ input: InputStream, _ output: OutputStream) throws {
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        input.open()
        defer { input.close() }
        while true {
            let n = input.read(&buf, maxLength: buf.count)
            if n < 0 { throw OtaError("ReadError: stream read failed") }
            if n == 0 { break }
            var written = 0
            while written < n {
                let w = buf.withUnsafeBytes { ptr in
                    output.write(ptr.baseAddress!.advanced(by: written).assumingMemoryBound(to: UInt8.self), maxLength: n - written)
                }
                guard w > 0 else { throw OtaError("WriteError: failed to write") }
                written += w
            }
        }
    }
}
