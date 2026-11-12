// Release.swift
// Port of com.linote.diffstudio.core.Release (Java, MIT).
//
// Index a full E5/MU300 release ZIP without mounting:
//  * E5: files/openwrt.ext4.gz (ext4 image, decompressed to a scratch
//    file) + files/boot.img, checksums from files/SHA256SUMS.
//  * MU300: mu300-openwrt.tar.gz + boot-linux.img, checksums from
//    desktop/manifest.json (magisk + desktop sections).

import Foundation

public final class Release {
    public typealias Progress = (String, String) -> Void

    /// A release ZIP on disk plus its user-visible name (used for patch naming).
    /// `cleanup`, when set, removes a scratch copy made by AppIO.
    public struct Source {
        public let url: URL
        public let displayName: String
        public let cleanup: (() -> Void)?
        public init(url: URL, displayName: String, cleanup: (() -> Void)? = nil) {
            self.url = url
            self.displayName = displayName
            self.cleanup = cleanup
        }
    }

    public let source: Source
    private let scratch: URL
    private let progress: Progress
    private var files: ZipIn?
    private var prefix = ""
    private var nameSet = Set<String>()

    public var family = ""
    public var meta = JsonObject()
    public var pkg = JsonObject()
    public var bootName = ""
    public var rootfsName = ""
    public var bootDigest = ""
    /// entries: name -> descriptor (insertion ordered)
    public var entries = OrderedMap<String, JsonObject>()
    public var packages = OrderedMap<String, JsonObject>()
    public var packageDb = Data()

    private var extfs: Ext4?
    private var imageURL: URL?
    private var imageHandle: FileHandle?
    private var extInum = [String: Int64]()

    public init(source: Source, scratch: URL, progress: Progress? = nil) throws {
        self.source = source
        self.scratch = scratch
        self.progress = progress ?? { _, _ in }
        do {
            try load()
        } catch {
            try? close()
            throw error
        }
    }

    private static func newDesc(mode: Int64, uid: Int64, gid: Int64) -> JsonObject {
        var d = JsonObject()
        d.put("mode", .int(mode))
        d.put("uid", .int(uid))
        d.put("gid", .int(gid))
        d.put("xattrs", .object(JsonObject()))
        return d
    }

    private func load() throws {
        let zip = try ZipIn(url: source.url)
        files = zip
        let names = zip.namelist()
        nameSet = Set(names)
        guard names.count == nameSet.count else {
            throw OtaError("Duplicate files in full package")
        }
        var matches: [String] = []
        for n in names where n.hasSuffix("files/device-profile.json") {
            matches.append(String(n.dropLast("files/device-profile.json".count)))
        }
        for n in names where n.hasSuffix("desktop/manifest.json") {
            matches.append(String(n.dropLast("desktop/manifest.json".count)))
        }
        guard matches.count == 1 else {
            throw OtaError("Select a single complete release ZIP")
        }
        prefix = matches[0]
        if exists("desktop/manifest.json") {
            try loadMu300(zip)
        } else {
            try loadE5(zip)
        }
        let bootStream = try open(bootName)
        bootStream.open()
        defer { bootStream.close() }
        bootDigest = try Py.digest(bootStream)
        for k in ["image_version", "profile", "kernel_release", "openwrt"] {
            guard case .string = meta[k] else {
                throw OtaError("Full release has no versioned \(k)")
            }
        }
    }

    private func loadMu300(_ zip: ZipIn) throws {
        family = "mu300"
        guard let m = Json.map(try json("desktop/release.json")),
              let p = Json.map(try json("desktop/manifest.json")) else {
            throw OtaError("AttributeError: release metadata is not an object")
        }
        meta = m
        pkg = p
        let mapping = Json.map(pkg["magisk_layout"]) ?? JsonObject()
        let rootfs: String
        if case .string(let s) = mapping["mu300-openwrt.tar.gz"] { rootfs = s } else { rootfs = "mu300-openwrt.tar.gz" }
        if case .string(let s) = mapping["boot-linux.img"] { bootName = s } else { bootName = "boot-linux.img" }
        guard pkg.contains("magisk") else { throw OtaError("KeyError: 'magisk'") }
        guard pkg.contains("desktop") else { throw OtaError("KeyError: 'desktop'") }
        var checks = Json.map(pkg["magisk"]) ?? JsonObject()
        if let desktop = Json.map(pkg["desktop"]) {
            for (k, v) in desktop.pairs { checks.put(k, v) }
        }
        try check(rootfs, Self.need(checks, rootfs))
        try check(bootName, Self.need(checks, bootName))
        if checks.contains("desktop/release.json") {
            try check("desktop/release.json", checks["desktop/release.json"]!)
        }
        let raw = try open(rootfs)
        raw.open()
        defer { raw.close() }
        let gz = GzipInputStream(raw)
        gz.open()
        defer { gz.close() }
        let tar = TarIn(gz)
        while let node = try tar.next() {
            var name = node.name.hasPrefix("./") ? String(node.name.dropFirst(2)) : node.name
            name = Py.rstripChars(name, "/")
            if name.isEmpty || name == "." { continue }
            _ = try Ota.safeName(name)
            guard !entries.contains(name) else {
                throw OtaError("Duplicate rootfs path: \(name)")
            }
            var d = Release.newDesc(mode: node.mode, uid: node.uid, gid: node.gid)
            var xattrs = Json.map(d["xattrs"]) ?? JsonObject()
            for (key, value) in node.pax.pairs where key.hasPrefix("SCHILY.xattr.") {
                let k = String(key.dropFirst("SCHILY.xattr.".count))
                xattrs.remove(k)
                xattrs.put(k, .string(Py.b64encode(value)))
            }
            d.put("xattrs", .object(xattrs))
            if node.isDir() {
                d.put("kind", .string("dir"))
            } else if node.isSym() {
                d.put("kind", .string("symlink"))
                d.put("target", .string(node.linkname))
            } else if node.isFile() {
                let stream = tar.content()
                stream.open()
                defer { stream.close() }
                if name == "lib/apk/db/installed" {
                    let raw2 = try Py.readUpTo(stream, limit: 32 << 20)
                    guard Int64(raw2.count) == node.size else {
                        throw OtaError("Oversized package database")
                    }
                    packageDb = raw2
                    packages = try Ota.packageVersions(raw2)
                    d.put("kind", .string("file"))
                    d.put("size", .int(node.size))
                    d.put("sha256", .string(Py.sha256Hex(raw2)))
                } else {
                    d.put("kind", .string("file"))
                    d.put("size", .int(node.size))
                    d.put("sha256", .string(try Py.digest(stream)))
                }
            } else if node.isLnk() {
                let target = node.linkname.hasPrefix("./") ? String(node.linkname.dropFirst(2)) : node.linkname
                guard let t = entries[target], t["kind"] == .string("file") else {
                    throw OtaError("Unsupported forward tar hardlink: \(name)")
                }
                d = t
            } else {
                continue
            }
            entries.put(name, d)
            progress("index", name)
        }
        rootfsName = rootfs
    }

    private func loadE5(_ zip: ZipIn) throws {
        family = "e5"
        guard let m = Json.map(try json("files/RELEASE.json")) else {
            throw OtaError("AttributeError: release metadata is not an object")
        }
        meta = m
        guard let p = Json.map(try json("files/device-profile.json")) else {
            throw OtaError("AttributeError: release metadata is not an object")
        }
        pkg = p
        var checks = JsonObject()
        let sumsStream = try open("files/SHA256SUMS")
        sumsStream.open()
        defer { sumsStream.close() }
        let sums = try Py.readAll(sumsStream)
        for line in Py.splitlines(try Py.decodeUtf8Strict([UInt8](sums))) {
            let parts = Py.splitWhitespace(line, maxsplit: 1)
            guard parts.count == 2 else {
                throw OtaError("not enough values to unpack (expected 2, got \(parts.count))")
            }
            var n = Py.strip(parts[1])
            if n.hasPrefix("*") { n = String(n.dropFirst()) }
            checks.remove(n)
            checks.put(n, .string(parts[0]))
        }
        bootName = "files/boot.img"
        rootfsName = "files/openwrt.ext4.gz"
        try check(rootfsName, Self.need(checks, rootfsName))
        try check(bootName, Self.need(checks, bootName))
        for name in ["files/RELEASE.json", "files/device-profile.json"] where checks.contains(name) {
            try check(name, checks[name]!)
        }
        // Decompress the ext4 image to a scratch file.
        let image = scratch.appendingPathComponent("tmp-\(UUID().uuidString).img")
        _ = FileManager.default.createFile(atPath: image.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: image) else {
            throw OtaError("Cannot create scratch file")
        }
        imageURL = image
        imageHandle = handle
        let compressed = try open(rootfsName)
        compressed.open()
        defer { compressed.close() }
        let gz = GzipInputStream(compressed)
        gz.open()
        defer { gz.close() }
        var total: Int64 = 0
        var block = [UInt8](repeating: 0, count: 4 << 20)
        let blockCount = block.count
        while true {
            var got = 0
            while got < blockCount {
                let n = block.withUnsafeMutableBytes { ptr in
                    gz.read(ptr.baseAddress!.advanced(by: got).assumingMemoryBound(to: UInt8.self), maxLength: blockCount - got)
                }
                if n < 0 { throw OtaError("ReadError: stream read failed") }
                if n == 0 { break }
                got += n
            }
            if got == 0 { break }
            total += Int64(got)
            guard total <= 16 << 30 else {
                throw OtaError("Root image exceeds 16 GiB")
            }
            if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: scratch.path),
               let free = attrs[.systemFreeSize] as? Int64, free < Int64(got) + (64 << 20) {
                throw OtaError("Insufficient temporary disk space")
            }
            try handle.write(contentsOf: Data(block[0..<got]))
            progress("decompress", rootfsName)
            if got < block.count { break }
        }
        try handle.close()
        imageHandle = nil
        extfs = try Ext4(url: image)
        try walk(try extfs!.root(), prefix: "", seen: [])
    }

    private func walk(_ node: Ext4.Inode, prefix: String, seen: Set<Int64>) throws {
        var seen = seen
        guard !seen.contains(node.inum) else {
            throw OtaError("Cyclic ext4 directory")
        }
        seen.insert(node.inum)
        defer { seen.remove(node.inum) }
        for child in try node.iterdir() {
            if child.filename == "." || child.filename == ".." { continue }
            let name = try Ota.safeName(prefix + child.filename)
            var d = Release.newDesc(mode: Int64(child.mode & 0o7777), uid: Int64(child.uidLow), gid: Int64(child.gidLow))
            var xattrs = Json.map(d["xattrs"]) ?? JsonObject()
            for (key, value) in try child.xattrs() {
                xattrs.remove(key)
                xattrs.put(key, .string(Py.b64encode(value)))
            }
            d.put("xattrs", .object(xattrs))
            let ft = child.filetype()
            if ft == Ext4.S_IFDIR {
                d.put("kind", .string("dir"))
            } else if ft == Ext4.S_IFLNK {
                d.put("kind", .string("symlink"))
                d.put("target", .string(try child.link()))
            } else if ft == Ext4.S_IFREG {
                let f = try child.open()
                f.open()
                defer { f.close() }
                d.put("kind", .string("file"))
                d.put("size", .int(child.size))
                d.put("sha256", .string(try Py.digest(f)))
                if name == "lib/apk/db/installed" {
                    let f2 = try child.open()
                    f2.open()
                    defer { f2.close() }
                    packageDb = try Py.readUpTo(f2, limit: 32 << 20)
                    packages = try Ota.packageVersions(packageDb)
                }
            } else {
                continue
            }
            entries.put(name, d)
            if extInum[name] == nil { extInum[name] = child.inum }
            progress("index", name)
            if d["kind"] == .string("dir") {
                try walk(child, prefix: name + "/", seen: seen)
            }
        }
    }

    public func exists(_ name: String) -> Bool {
        nameSet.contains(prefix + name)
    }

    public func open(_ name: String) throws -> InputStream {
        _ = try Ota.safeName(name)
        guard let files else { throw OtaError("Release closed") }
        return try files.open(prefix + name)
    }

    public func json(_ name: String) throws -> JsonValue {
        let stream = try open(name)
        stream.open()
        defer { stream.close() }
        return try Json.parse(Py.readAll(stream))
    }

    public func check(_ name: String, _ wanted: JsonValue?) throws {
        let stream = try open(name)
        stream.open()
        defer { stream.close() }
        guard let wanted, case .string(let want) = wanted,
              try Py.digest(stream) == want else {
            throw OtaError("Full package checksum mismatch: \(name)")
        }
    }

    private static func need(_ m: JsonObject, _ key: String) throws -> JsonValue {
        guard let v = m[key] else { throw OtaError("KeyError: \(Py.repr(key))") }
        return v
    }

    private static func copy(_ input: InputStream, _ output: OutputStream) throws {
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
                guard w > 0 else { throw OtaError("WriteError: failed to write blob") }
                written += w
            }
        }
    }

    /// write_blobs(archive, wanted)
    public func writeBlobs(_ archive: ZipOut, wanted: Set<String>, progress p: Progress) throws {
        var pending = wanted
        if let extfs {
            for (name, desc) in entries.pairs {
                guard let sha = desc["sha256"], case .string(let shaStr) = sha,
                      pending.contains(shaStr) else { continue }
                guard let inum = extInum[name] else {
                    throw OtaError("FileNotFoundError: \(name)")
                }
                let node = try extfs.inode(inum)
                let src = try node.open()
                let dst = try archive.openEntry("blobs/" + shaStr)
                defer { dst.close() }
                try Release.copy(src, dst)
                pending.remove(shaStr)
                p("write", name)
            }
        } else {
            let raw = try open(rootfsName)
            raw.open()
            defer { raw.close() }
            let gz = GzipInputStream(raw)
            gz.open()
            defer { gz.close() }
            let tar = TarIn(gz)
            while let node = try tar.next() {
                var name = node.name.hasPrefix("./") ? String(node.name.dropFirst(2)) : node.name
                name = Py.rstripChars(name, "/")
                guard let d = entries[name],
                      let sha = d["sha256"], case .string(let shaStr) = sha,
                      pending.contains(shaStr), node.isFile() else { continue }
                let dst = try archive.openEntry("blobs/" + shaStr)
                defer { dst.close() }
                try Release.copy(tar.content(), dst)
                pending.remove(shaStr)
                p("write", name)
            }
        }
        guard pending.isEmpty else {
            throw OtaError("Cannot find payload content: \(pending.sorted().joined(separator: ", "))")
        }
    }

    public func close() throws {
        try? imageHandle?.close()
        imageHandle = nil
        if let imageURL {
            try? FileManager.default.removeItem(at: imageURL)
            self.imageURL = nil
        }
        try? files?.close()
        files = nil
        extfs = nil
        source.cleanup?()
    }
}
