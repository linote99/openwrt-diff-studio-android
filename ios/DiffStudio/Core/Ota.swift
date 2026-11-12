// Ota.swift
// Port of com.linote.diffstudio.core.Ota (Java, MIT).
//
// Port of ota_engine.py parts used on the generator / desktop side
// (protocol 2, "unisoc-diff-ota-2").

import Foundation

public enum Ota {
    public static let FORMAT = "unisoc-diff-ota-2"
    public static let MAX_MANIFEST: Int64 = 16 << 20
    public static let MAX_BYTES: Int64 = 2 << 30
    public static let MAX_FILES = 50000
    public static let STATE = "etc/unisoc-ota"
    public static let PROTECTED = ["lib/firmware", "lib/apk", "usr/lib/opkg", "usr/lib/apk",
                                   "opt/e5/vendor", "opt/e5/firmware", "opt/e5/nv", "opt/e5/android",
                                   "opt/mu300/vendor", "opt/mu300/firmware", "opt/mu300/nv",
                                   "etc/e5-nv", "etc/unisoc-ota", "etc/uci-defaults"]

    private static let hexPattern = "^[0-9a-f]{64}$"
    private static let versionPattern = "^[A-Za-z0-9._+\\-]{1,180}$"

    public static func isHex(_ v: JsonValue?) -> Bool {
        guard case .string(let s) = v else { return false }
        return s.range(of: hexPattern, options: .regularExpression) != nil
    }

    public static func safeName(_ o: JsonValue?) throws -> String {
        var bad = false
        var name = ""
        if case .string(let s) = o {
            name = s
            bad = name.isEmpty || Py.pyLen(name) > 2048 || name.contains("\\") || name.contains("\0")
                || name.hasPrefix("/")
            if !bad {
                for scalar in name.unicodeScalars where scalar.value < 32 { bad = true; break }
            }
            if !bad {
                for part in name.split(separator: "/", omittingEmptySubsequences: false) {
                    if part.isEmpty || part == "." || part == ".." { bad = true; break }
                }
                // split(separator:) drops a trailing empty part; Java's
                // split("/", -1) keeps it, so a trailing "/" is unsafe too.
                if !bad, name.hasSuffix("/") { bad = true }
            }
        } else {
            bad = true
        }
        if bad { throw OtaError("Unsafe path: \(Py.repr(o))") }
        return name
    }

    public static func safeName(_ s: String) throws -> String {
        try safeName(.string(s))
    }

    public static func isProtected(_ name: String) throws -> Bool {
        _ = try safeName(name)
        let top = name.split(separator: "/", maxSplits: 1).first.map(String.init) ?? name
        switch top {
        case "bin", "sbin", "lib", "lib64", "usr", "opt", "etc", "www":
            break
        default:
            return true
        }
        if name.hasPrefix("etc/") && !(name.hasPrefix("etc/init.d/") || name.hasPrefix("etc/hotplug.d/") || name.hasPrefix("etc/uci-defaults/")) {
            return true
        }
        for p in PROTECTED where name == p || name.hasPrefix(p + "/") { return true }
        return false
    }

    /// package_versions(raw): {P: {V, A, D}}
    public static func packageVersions(_ raw: Data) throws -> OrderedMap<String, JsonObject> {
        var result = OrderedMap<String, JsonObject>()
        let text = try Py.decodeUtf8Strict([UInt8](raw))
        for paragraph in text.components(separatedBy: "\n\n") {
            var fields = OrderedMap<Character, String>()
            for line in Py.splitlines(paragraph) {
                let scalars = Array(line.unicodeScalars)
                if Py.pyLen(line) > 2, scalars.count > 1, scalars[1] == ":",
                   !(scalars[0].value >= 0xD800 && scalars[0].value <= 0xDFFF) {
                    fields.put(Character(scalars[0]), String(line.dropFirst(2)))
                }
            }
            if let p = fields["P"] {
                var v = JsonObject()
                for k: Character in ["V", "A", "D"] {
                    v.put(String(k), .string(fields[k] ?? ""))
                }
                result.remove(p)
                result.put(p, v)
            }
        }
        return result
    }

    public static func validateDescriptor(_ value: JsonValue?) throws {
        guard let value, !value.isNull else { return }
        guard let v = Json.map(value) else { return }
        guard let kind = v["kind"], case .string(let kindStr) = kind,
              kindStr == "file" || kindStr == "symlink" || kindStr == "dir" else {
            throw OtaError("Invalid file descriptor")
        }
        for (key, limit) in [("mode", Int64(0o7777)), ("uid", Int64(65535)), ("gid", Int64(65535))] {
            let x = v[key]
            guard let x, Json.isInt(x), Json.asLong(x) >= 0, Json.asLong(x) <= limit else {
                throw OtaError("Invalid file permissions/ownership")
            }
        }
        if kindStr == "file" {
            let sha: JsonValue? = v.contains("sha256") ? v["sha256"] : .string("")
            guard case .string = sha else {
                throw OtaError("TypeError: expected string or bytes-like object")
            }
            let size = v["size"]
            guard isHex(sha), let size, Json.isInt(size), Json.asLong(size) >= 0, Json.asLong(size) <= MAX_BYTES else {
                throw OtaError("Invalid file hash/size")
            }
        }
        if kindStr == "symlink" {
            guard let t = v["target"], case .string(let target) = t,
                  !target.isEmpty, Py.pyLen(target) <= 4096, !target.contains("\0") else {
                throw OtaError("Invalid symbolic link")
            }
        }
        let xa: JsonValue? = v.contains("xattrs") ? v["xattrs"] : .object(JsonObject())
        guard let xm = Json.map(xa) else {
            throw OtaError("AttributeError: xattrs has no attribute 'items'")
        }
        for (name, val) in xm.pairs {
            guard case .string(let b64) = val else {
                throw OtaError("TypeError: argument should be a bytes-like object or ASCII string")
            }
            let decoded = try Py.b64decodeStrict(b64)
            if name.isEmpty || name.contains("\0") || decoded.count > 65536 {
                throw OtaError("Invalid extended attribute")
            }
        }
    }

    @discardableResult
    public static func validateManifest(_ mo: JsonValue?) throws -> JsonObject {
        guard let m = Json.map(mo), m["format"] == .string(FORMAT) else {
            throw OtaError("Unsupported OTA format")
        }
        guard let fam = m["family"], case .string(let famStr) = fam,
              (famStr == "e5" || famStr == "mu300"),
              case .string = m["profile"] else {
            throw OtaError("Invalid OTA family/profile")
        }
        for k in ["base_version", "target_version", "kernel_release"] {
            guard let v = m[k], case .string(let s) = v,
                  s.range(of: versionPattern, options: .regularExpression) != nil else {
                throw OtaError("Invalid \(k)")
            }
        }
        if m["base_version"] == m["target_version"] {
            throw OtaError("Release versions are identical")
        }
        guard let ops = Json.list(m["operations"]), ops.count <= MAX_FILES,
              !(ops.isEmpty && !Json.truthy(m["boot"])) else {
            throw OtaError("Empty or excessive OTA operations")
        }
        var seen = Set<String>()
        var firstByPath = OrderedMap<String, JsonObject>()
        for oo in ops {
            guard let op = Json.map(oo) else {
                throw OtaError("TypeError: operation must be an object")
            }
            guard op.contains("path") else { throw OtaError("KeyError: 'path'") }
            let name = try safeName(op["path"])
            let merge = op["merge"]
            let mergeStr: String? = {
                if case .string(let s) = merge { return s }
                return nil
            }()
            let special = (mergeStr == "apk-db" && name == "lib/apk/db/installed")
                || (mergeStr == "apk-scripts" && name == "lib/apk/db/scripts.tar")
                || (mergeStr == "apk-triggers" && name == "lib/apk/db/triggers")
                || (mergeStr == "release" && (name == "etc/e5/release.json" || name == "etc/mu300/release.json"))
                || (mergeStr == "accounts" && (name == "etc/passwd" || name == "etc/shadow" || name == "etc/group" || name == "etc/gshadow"))
                || (mergeStr == "world" && name == "etc/apk/world")
                || (mergeStr == "default" && name.hasPrefix("etc/") && !(name.hasPrefix("etc/unisoc-ota/") || name.hasPrefix("etc/uci-defaults/")))
            if merge != nil, !merge!.isNull, !special {
                throw OtaError("Invalid merge operation")
            }
            let prot = try isProtected(name)
            if seen.contains(name) || (prot && !special) {
                throw OtaError("Duplicate/protected OTA path: \(name)")
            }
            seen.insert(name)
            if !firstByPath.contains(name) { firstByPath.put(name, op) }
            let before = op["before"], after = op["after"]
            try validateDescriptor(before)
            try validateDescriptor(after)
            if Json.pyEquals(before, after) || (before == nil && after == nil) {
                throw OtaError("Redundant operation")
            }
            if Json.truthy(before),
               let bm = Json.map(before), bm["kind"] == .string("dir"),
               (!Json.truthy(after) || Json.map(after)?["kind"] != .string("dir")) {
                throw OtaError("Directory removal/type change is not supported: \(name)")
            }
        }
        for name in seen {
            var p = name
            while p.contains("/") {
                p = String(p[..<p.lastIndex(of: "/")!])
                if seen.contains(p) {
                    guard let op = firstByPath[p] else { continue }
                    guard op.contains("after") else { throw OtaError("KeyError: 'after'") }
                    let a = op["after"]
                    if !Json.truthy(a) || Json.map(a)?["kind"] != .string("dir") {
                        throw OtaError("Operation below a non-directory: \(name)")
                    }
                }
            }
        }
        for key in ["boot", "busybox", "bootstrap"] where m.contains(key) {
            let v = Json.map(m[key])
            let sha: JsonValue? = v?.contains("sha256") == true ? v?["sha256"] : .string("")
            let size = v?["size"]
            guard v != nil, isHex(sha), let size, Json.isInt(size), Json.asLong(size) > 0, Json.asLong(size) <= MAX_BYTES else {
                throw OtaError("Invalid \(key) payload")
            }
        }
        let rt: JsonValue? = m.contains("runtime") ? m["runtime"] : .object(JsonObject())
        guard let runtime = Json.map(rt) else {
            throw OtaError("AttributeError: runtime has no attribute 'items'")
        }
        for (name, value) in runtime.pairs {
            let safe = try safeName(.string(name))
            let top = safe.split(separator: "/", maxSplits: 1).first.map(String.init) ?? safe
            guard top == "lib" || top == "lib64" || top == "usr" || top == "ota" else {
                throw OtaError("Invalid runtime path")
            }
            try validateDescriptor(value)
            if value.isNull || Json.map(value)?["kind"] == .string("dir") {
                throw OtaError("Invalid runtime entry")
            }
        }
        return m
    }

    public typealias BlobProgress = (Int, Int) -> Void

    /// ota_engine.Patch: validated, checksum-verified differential archive.
    public final class Patch {
        public let archive: ZipIn
        public let manifest: JsonObject
        public let id: String

        public init(url: URL, progress: BlobProgress? = nil) throws {
            archive = try ZipIn(url: url)
            do {
                let names = archive.namelist()
                guard names.count == Set(names).count, names.count <= MAX_FILES + 1 else {
                    throw OtaError("Duplicate/excessive ZIP entries")
                }
                let info = try archive.getinfo("manifest.json")
                guard info.size <= UInt64(MAX_MANIFEST) else {
                    throw OtaError("OTA manifest too large")
                }
                let raw: Data
                do {
                    let stream = try archive.open("manifest.json")
                    stream.open()
                    defer { stream.close() }
                    raw = try Py.readAll(stream)
                }
                manifest = try validateManifest(Json.parse(raw))
                id = Py.sha256Hex(Json.canonical(.object(manifest)))
                var blobs = OrderedMap<String, Int64>()
                if let ops = Json.list(manifest["operations"]) {
                    for oo in ops {
                        if let after = Json.map(Json.map(oo)?["after"]),
                           Json.truthy(.object(after)), after["kind"] == .string("file"),
                           let sha = after["sha256"], case .string(let shaStr) = sha,
                           let size = after["size"] {
                            blobs.put(shaStr, Json.asLong(size))
                        }
                    }
                }
                if let runtime = Json.map(manifest["runtime"]) {
                    for d in runtime.values {
                        if let dm = Json.map(d), dm["kind"] == .string("file"),
                           let sha = dm["sha256"], case .string(let shaStr) = sha,
                           let size = dm["size"] {
                            blobs.put(shaStr, Json.asLong(size))
                        }
                    }
                }
                for key in ["boot", "busybox", "bootstrap"] where manifest.contains(key) {
                    if let d = Json.map(manifest[key]),
                       let sha = d["sha256"], case .string(let shaStr) = sha,
                       let size = d["size"] {
                        blobs.put(shaStr, Json.asLong(size))
                    }
                }
                var expected = Set<String>(["manifest.json"])
                for h in blobs.keys { expected.insert("blobs/" + h) }
                guard Set(names) == expected else {
                    throw OtaError("Unexpected or missing archive entries")
                }
                var total: Int64 = 0
                for s in blobs.values { total += s }
                guard total <= MAX_BYTES else {
                    throw OtaError("OTA exceeds expanded size limit")
                }
                var done = 0
                for (hash, size) in blobs.pairs {
                    let e = try archive.getinfo("blobs/" + hash)
                    guard e.size == UInt64(size), (e.flags & 1) == 0 else {
                        throw OtaError("Invalid encrypted blob or length")
                    }
                    let stream = try archive.open("blobs/" + hash)
                    stream.open()
                    defer { stream.close() }
                    guard try Py.digest(stream) == hash else {
                        throw OtaError("OTA content checksum mismatch: \(hash)")
                    }
                    done += 1
                    progress?(done, blobs.count)
                }
            } catch {
                try? archive.close()
                throw error
            }
        }

        public func blob(_ sha: String) throws -> Data {
            try archive.read("blobs/" + sha)
        }

        public func close() throws {
            try archive.close()
        }
    }
}
