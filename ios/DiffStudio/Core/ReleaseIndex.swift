// ReleaseIndex.swift
// Port of com.linote.diffstudio.core.ReleaseIndex (Java, MIT).
//
// Port of release_index.py (desktop 2026-10-26): portable,
// content-checked release baselines. An index holds a release's
// identity, file table, package versions and boot hash, but no payload
// or device data. It can stand in for the old full release when
// generating the next patch.

import Foundation

public enum ReleaseIndex {
    public static let FORMAT = "openwrt-release-index"
    public static let SUFFIX = ".owrt-index.json"
    public static let MAX_SIZE: Int64 = 64 << 20

    /// The attributes compare() reads from the old release; a full
    /// Release or a loaded index.
    public struct Base {
        public let family: String
        public let meta: JsonObject
        public let entries: OrderedMap<String, JsonObject>
        public let packages: OrderedMap<String, JsonObject>
        public let bootDigest: String

        public init(family: String, meta: JsonObject, entries: OrderedMap<String, JsonObject>,
                    packages: OrderedMap<String, JsonObject>, bootDigest: String) {
            self.family = family
            self.meta = meta
            self.entries = entries
            self.packages = packages
            self.bootDigest = bootDigest
        }

        public static func of(_ r: Release) -> Base {
            Base(family: r.family, meta: r.meta, entries: r.entries, packages: r.packages, bootDigest: r.bootDigest)
        }
    }

    private static let profilePattern = "^[a-z0-9][a-z0-9_-]{0,63}$"
    private static let hex64Pattern = "^[a-f0-9]{64}$"
    private static let topKeys: Set<String> = ["format", "version", "sha256", "release"]
    private static let releaseKeys: Set<String> = ["family", "meta", "entries", "packages", "boot_digest"]
    private static let metaKeys: Set<String> = ["profile", "image_version", "kernel_release", "openwrt"]
    private static let descKeys: Set<String> = ["kind", "mode", "uid", "gid", "size", "sha256", "target", "xattrs"]
    private static let vadKeys: Set<String> = ["V", "A", "D"]

    private static func idString(_ v: JsonValue?) -> Bool {
        guard case .string(let s) = v else { return false }
        if s.isEmpty || Py.pyLen(s) > 256 { return false }
        return !s.unicodeScalars.contains { $0.value < 32 }
    }

    @discardableResult
    public static func validate(_ value: JsonValue?) throws -> JsonObject {
        guard let data = Json.map(value),
              Set(data.keys) == topKeys,
              data["format"] == .string(FORMAT),
              let version = data["version"], Json.isInt(version),
              Json.pyEquals(version, .int(1)) else {
            throw OtaError("Unsupported release index / 不支持的版本摘要格式")
        }
        guard let release = Json.map(data["release"]),
              Set(release.keys) == releaseKeys else {
            throw OtaError("Incomplete release index / 版本摘要不完整")
        }
        guard Py.sha256Hex(Json.canonical(.object(release))) == {
            if case .string(let s) = data["sha256"] { return s }
            return ""
        }() else {
            throw OtaError("Release index checksum mismatch / 版本摘要校验失败")
        }
        guard let family = release["family"], case .string(let fam) = family,
              fam == "e5" || fam == "mu300" else {
            throw OtaError("Invalid release index family")
        }
        guard let meta = Json.map(release["meta"]),
              Set(meta.keys) == metaKeys,
              meta.values.allSatisfy({ idString($0) }) else {
            throw OtaError("Invalid release index identity")
        }
        guard let profile = meta["profile"], case .string(let profileStr) = profile,
              profileStr.range(of: profilePattern, options: .regularExpression) != nil,
              let boot = release["boot_digest"], case .string(let bootStr) = boot,
              bootStr.range(of: hex64Pattern, options: .regularExpression) != nil else {
            throw OtaError("Invalid release index profile/boot hash")
        }
        guard let entries = Json.map(release["entries"]),
              !entries.isEmpty, entries.count <= 250000 else {
            throw OtaError("Invalid release index file table")
        }
        for (key, d) in entries.pairs {
            _ = try Ota.safeName(key)
            guard let desc = Json.map(d),
                  (desc.contains("xattrs") ? Json.map(desc["xattrs"]) != nil : true),
                  descKeys.isSuperset(of: Set(desc.keys)) else {
                throw OtaError("Invalid release index descriptor")
            }
            try Ota.validateDescriptor(d)
        }
        guard let packages = Json.map(release["packages"]) else {
            throw OtaError("Invalid release index packages")
        }
        var pkgOk = true
        for (k, v) in packages.pairs {
            guard !k.isEmpty, Py.pyLen(k) <= 256,
                  let vm = Json.map(v), Set(vm.keys) == vadKeys else { pkgOk = false; break }
            for x in vm.values {
                guard case .string(let s) = x, Py.pyLen(s) <= 65536 else { pkgOk = false; break }
            }
            if !pkgOk { break }
        }
        guard pkgOk else {
            throw OtaError("Invalid release index packages")
        }
        return data
    }

    /// snapshot(release): must run after compare(), which adds the
    /// updater files this generator ships.
    public static func snapshot(_ release: Release) throws -> JsonObject {
        var meta = JsonObject()
        for k in ["profile", "image_version", "kernel_release", "openwrt"] {
            guard let v = release.meta[k] else {
                throw OtaError("KeyError: '\(k)'")
            }
            meta.put(k, v)
        }
        var body = JsonObject()
        body.put("family", .string(release.family))
        body.put("meta", .object(meta))
        body.put("entries", .object(Json.objectOfDescriptors(release.entries)))
        body.put("packages", .object(Json.objectOfDescriptors(release.packages)))
        body.put("boot_digest", .string(release.bootDigest))
        var data = JsonObject()
        data.put("format", .string(FORMAT))
        data.put("version", .int(1))
        data.put("sha256", .string(Py.sha256Hex(Json.canonical(.object(body)))))
        data.put("release", .object(body))
        return try validate(.object(data))
    }

    public static func readIndex(_ stream: InputStream) throws -> JsonObject {
        stream.open()
        defer { stream.close() }
        let raw = try Py.readUpTo(stream, limit: MAX_SIZE + 1)
        guard Int64(raw.count) <= MAX_SIZE else {
            throw OtaError("Release index exceeds 64 MiB")
        }
        do {
            return try validate(Json.parseUnique(raw))
        } catch let e as OtaError {
            if e.message.hasPrefix("UnicodeDecodeError") {
                throw OtaError("Invalid release index / 版本摘要损坏")
            }
            throw e
        } catch {
            throw OtaError("Invalid release index / 版本摘要损坏")
        }
    }

    public static func readIndex(url: URL) throws -> JsonObject {
        guard let stream = InputStream(url: url) else {
            throw OtaError("Cannot open \(url.lastPathComponent)")
        }
        return try readIndex(stream)
    }

    public static func load(_ stream: InputStream) throws -> Base {
        let release = Json.map(try readIndex(stream)["release"])!
        var entries = OrderedMap<String, JsonObject>()
        if let em = Json.map(release["entries"]) {
            for (k, v) in em.pairs {
                if let d = Json.map(v) { entries.put(k, d) }
            }
        }
        var packages = OrderedMap<String, JsonObject>()
        if let pm = Json.map(release["packages"]) {
            for (k, v) in pm.pairs {
                if let d = Json.map(v) { packages.put(k, d) }
            }
        }
        guard let family = release["family"], case .string(let fam) = family,
              let meta = Json.map(release["meta"]),
              let boot = release["boot_digest"], case .string(let bootStr) = boot else {
            throw OtaError("Invalid release index / 版本摘要损坏")
        }
        return Base(family: fam, meta: meta, entries: entries, packages: packages, bootDigest: bootStr)
    }

    /// canonical(data) + b'\n'
    public static func serialize(_ data: JsonObject) throws -> Data {
        _ = try validate(.object(data))
        var raw = Json.canonical(.object(data))
        raw.append(0x0A)
        guard Int64(raw.count) <= MAX_SIZE else {
            throw OtaError("Release index exceeds 64 MiB")
        }
        return raw
    }

    @discardableResult
    public static func writeIndex(path: URL, data: JsonObject, reuse: Bool) throws -> URL {
        let raw = try serialize(data)
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: path.path) {
            if reuse, Json.pyEquals(.object(try readIndex(url: path)), .object(data)) {
                return path
            }
            throw OtaError("Release index destination already exists / 版本摘要目标文件已存在: \(path.path)")
        }
        let temp = dir.appendingPathComponent(".release-index-\(UUID().uuidString)")
        do {
            try raw.write(to: temp)
            try FileManager.default.moveItem(at: temp, to: path)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        return path
    }

    public static func saveIndex(_ release: Release, directory: URL) throws -> URL {
        let data = try snapshot(release)
        guard case .string(let version) = release.meta["image_version"] else {
            throw OtaError("KeyError: 'image_version'")
        }
        var label = version.map { c in
            (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-") ? c : "_"
        }
        if label.count > 100 { label = Array(label.prefix(100)) }
        guard case .string(let sha) = data["sha256"] else {
            throw OtaError("Invalid release index")
        }
        let path = directory.appendingPathComponent("OpenWrt-\(String(label))-\(sha)\(SUFFIX)")
        return try writeIndex(path: path, data: data, reuse: true)
    }
}
