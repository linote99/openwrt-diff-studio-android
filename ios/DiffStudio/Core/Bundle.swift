// Bundle.swift
// Port of com.linote.diffstudio.core.Bundle (Java, MIT).
//
// Port of ota_bundle.export_bundle for iOS: update.ota + fingerprinted
// Python updater + README, zipped as a full update package.

import Foundation

public enum Bundle {
    public protocol Files {
        func open(_ name: String) throws -> InputStream
    }

    /// Files served from the app bundle's Assets directory.
    public struct BundleFiles: Files {
        public let base: URL
        public init(base: URL) { self.base = base }
        public func open(_ name: String) throws -> InputStream {
            let url = base.appendingPathComponent(name)
            guard let stream = InputStream(url: url) else {
                throw OtaError("Missing or unsafe native runtime file")
            }
            return stream
        }
    }

    public static let README = "# OpenWrt differential OTA\n\n"
        + "Web: import update.ota in System > System patches.\n"
        + "Android: open OpenWrt Diff Studio, choose Update device, select update.ota and connect to DEVICE_IP.\n"
        + "Desktop: use the OpenWrt Diff Studio desktop edition for this device family, or the Python updater below.\n"
        + "Python: python OpenWrt-Updater.py update update.ota --host DEVICE_IP (requires paramiko).\n\n"
        + "网页：系统 → 系统补丁，导入 update.ota。\n"
        + "安卓：打开 OpenWrt Diff Studio → 更新设备，选择 update.ota 后连接设备。\n"
        + "电脑：完整解压后运行 python OpenWrt-Updater.py update update.ota --host 设备地址（需要 paramiko）。\n"
        + "仅使用可信补丁；先核对目标版本、机型和冲突检查。\n"
        + "更新后请重启；网页支持撤销上次补丁。\n"
        + "旧系统没有 OTA 插件／Python：使用安卓或电脑更新程序首次更新，完成后即可在网页导入后续补丁。\n"
        + "Old system without OTA/Python: use the Android or desktop updater once; subsequent patches can be imported in LuCI.\n"

    public static func export(patch: URL, output: URL, runtime: Files) throws {
        let manifestStream = try runtime.open("files.json")
        manifestStream.open()
        defer { manifestStream.close() }
        let build = Json.map(try Json.parse(Py.readAll(manifestStream)))
        let files = build.flatMap { Json.map($0["files"]) }
        guard let build, Json.pyEquals(build["protocol"], .int(1)),
              let files, !files.isEmpty else {
            throw OtaError("Missing Diff Studio runtime manifest; run installer/build-ota.py")
        }
        for (name, wanted) in files.pairs {
            _ = try Ota.safeName(name)
            let stream: InputStream
            do {
                stream = try runtime.open(name)
            } catch {
                throw OtaError("Missing or unsafe native runtime file")
            }
            stream.open()
            defer { stream.close() }
            guard case .string(let want) = wanted,
                  try Py.digest(stream) == want else {
                throw OtaError("Native runtime checksum mismatch: \(name)")
            }
        }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw OtaError("Output already exists")
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
        let z = try ZipOut(url: tmp)
        var ok = false
        do {
            guard let patchStream = InputStream(url: patch) else {
                throw OtaError("Cannot open \(patch.lastPathComponent)")
            }
            let out = try z.openEntry("update.ota")
            defer { out.close() }
            try OtaPackage.copy(patchStream, out)
            for name in files.keys {
                // Unix 0644 so the Python updater extracts readable on Linux/macOS
                let stream = try runtime.open(name)
                let entry = try z.openEntry(name, unixMode: 0o644)
                defer { entry.close() }
                try OtaPackage.copy(stream, entry)
            }
            try z.writeBytes("README.md", Data(README.utf8))
            ok = true
        } catch {
            z.abort()
            throw error
        }
        if ok { try z.close() }
        do {
            try FileManager.default.moveItem(at: tmp, to: output)
        } catch {
            throw OtaError("Cannot move finished bundle into place")
        }
    }
}
