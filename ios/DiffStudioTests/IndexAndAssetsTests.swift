// IndexAndAssetsTests.swift
// New tests for this port: a .owrt-index.json round-trips through
// serialize / writeIndex / readIndex, tampering is rejected, and the
// bundled device-side assets are byte-identical to the Android app's
// assets (hashes recorded from
// openwrt-diff-studio-android v1.1.2, app/src/main/assets/).

import XCTest
@testable import DiffStudio

final class IndexAndAssetsTests: XCTestCase {
    /// A minimal valid index body, built the same way
    /// ReleaseIndex.snapshot() builds one.
    private func makeIndex() -> JsonObject {
        var meta = JsonObject()
        meta.put("profile", .string("f50pro"))
        meta.put("image_version", .string("r20261106.144559-g0696fbc2"))
        meta.put("kernel_release", .string("6.12.94-u30pro-p1"))
        meta.put("openwrt", .string("25.12.5"))

        var desc = JsonObject()
        desc.put("kind", .string("file"))
        desc.put("mode", .int(0o644))
        desc.put("uid", .int(0))
        desc.put("gid", .int(0))
        desc.put("size", .int(4))
        desc.put("sha256", .string("9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"))

        var entries = OrderedMap<String, JsonObject>()
        entries.put("etc/banner", desc)

        var pkg = JsonObject()
        pkg.put("V", .string("1.0"))
        pkg.put("A", .string("aarch64_cortex-a53"))
        pkg.put("D", .string(""))
        var packages = OrderedMap<String, JsonObject>()
        packages.put("base-files", pkg)

        var body = JsonObject()
        body.put("family", .string("e5"))
        body.put("meta", .object(meta))
        body.put("entries", .object(Json.objectOfDescriptors(entries)))
        body.put("packages", .object(Json.objectOfDescriptors(packages)))
        body.put("boot_digest", .string(String(repeating: "a", count: 64)))

        var data = JsonObject()
        data.put("format", .string(ReleaseIndex.FORMAT))
        data.put("version", .int(1))
        data.put("sha256", .string(Py.sha256Hex(Json.canonical(.object(body)))))
        data.put("release", .object(body))
        return data
    }

    func testIndexRoundTrip() throws {
        let data = makeIndex()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffStudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("OpenWrt-test\(ReleaseIndex.SUFFIX)")
        let written = try ReleaseIndex.writeIndex(path: path, data: data, reuse: false)
        XCTAssertEqual(written, path)

        let raw = try ReleaseIndex.serialize(data)
        XCTAssertEqual(try Data(contentsOf: path), raw, "written bytes must be the canonical serialization")

        let readBack = try ReleaseIndex.readIndex(url: path)
        XCTAssertEqual(try ReleaseIndex.serialize(readBack), raw, "read back must re-serialize identically")

        let base = try ReleaseIndex.load(InputStream(url: path)!)
        XCTAssertEqual(base.family, "e5")
        XCTAssertEqual(base.bootDigest, String(repeating: "a", count: 64))
        XCTAssertEqual(base.entries.count, 1)
        XCTAssertEqual(base.packages.count, 1)
    }

    func testIndexTamperRejected() throws {
        let data = makeIndex()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffStudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("OpenWrt-test\(ReleaseIndex.SUFFIX)")
        try ReleaseIndex.writeIndex(path: path, data: data, reuse: false)

        var raw = try Data(contentsOf: path)
        // Flip one byte inside the release body; the sha256 must no longer match.
        let idx = raw.count - 20
        raw[idx] = raw[idx] == 0x61 ? 0x62 : 0x61
        try raw.write(to: path)

        XCTAssertThrowsError(try ReleaseIndex.readIndex(url: path)) { error in
            XCTAssertTrue(error is OtaError)
        }
    }

    /// Expected SHA-256 of every bundled asset file, recorded from the
    /// Android repo (v1.1.2). Regenerate from
    /// app/src/main/assets/ if the Android assets change.
    private static let expectedAssetHashes: [String: String] = [
        "bundle/common/OpenWrt-Updater.py": "1da55725c05f110c4b3d64bbe2e9a60d8de347f5e7b9e50261ba88bed62ce020",
        "bundle/common/backend/__init__.py": "4227d63763e764fd2de7fc2bc13e474ae5de33176fb57aa0fd51cbb4ad80b88c",
        "bundle/common/backend/boot.py": "5e33608777082aaa6993f9ddde2e35850d1907bb22936b78d79975ce8d258587",
        "bundle/common/backend/errors.js": "336cd4e51521cd481ccfb8e58d448ca32a4ec879054fa253d1bb96a17578ba99",
        "bundle/common/backend/host.py": "c799de271fef9d9031add32bd411e1bcfa6cec747d7cb1d75cd153d82b6d327d",
        "bundle/common/backend/lz4raw-aarch64.so": "1ee6ed4929b19be39e607e9bcfb48a3402a7008ced54bf74e34071596d900bde",
        "bundle/common/backend/ota_bundle.py": "43ea0b0f87a53ed0cc1564e8c29de6d4d4971c0e32f7f59b58766ff7d6d1da55",
        "bundle/common/backend/ota_desktop.py": "75aa4717b255213e838a65757e875d0a77aac28fe637282d625bcb47646a3d76",
        "bundle/common/backend/ota_package.py": "dea8e995ad7779cf3d2291621cd19166cb3462704fe13989263d5538576e3601",
        "bundle/common/backend/ota_runtime.py": "0ad61eb388f580874d1b03b7e018c6c78d23e0a0065538c1d7ff9ea66ac62b64",
        "bundle/common/backend/proxy.sh": "80839c4e52bd251c027e6c409a46c52c478acb6311a7720945b49fa5ca5db327",
        "bundle/common/backend/release_index.py": "f4077a50bfee00bbbf3d332c638d61f0fcd08dbc76c8d55931a9cb71e44f6f0c",
        "bundle/common/backend/resources.py": "7f686d135d640ed94b5c5a35cb872532091cf57a51591639f5bd23ed06dec5a4",
        "bundle/common/backend/rpc.py": "296301376786c881766ca80aef7f6f1482444fa6fb58d3e0b35f17237de299a5",
        "bundle/common/backend/ssh_runtime.py": "f707ca9f5f7c8dcdf1d77d6d5d125e8a06c8124cdc0d3525e8e4ca74ec33bc4d",
        "bundle/common/backend/unisoc-ota.js": "e4252e6f1c5727053d61d2759f395c9c076ed559d8ca4cc730d3288a875d50dc",
        "bundle/common/backend/unisoc-ota.json": "696a533e918368dcf009855b76fa9388ff3311656abc161a12cbaf5564a04c42",
        "bundle/e5/files.json": "83cf1e783622c77e7346cbdbfdfef60da5664c784d690e666f848dfab69ba7a4",
        "bundle/mu300/files.json": "e206883fe03efb578cc435e8c5673ad4b41ccfd7cff1954868e3fb8023f243e3",
        "ota/boot.py": "5e33608777082aaa6993f9ddde2e35850d1907bb22936b78d79975ce8d258587",
        "ota/e5/engine.py": "40490c56d595963dd674775a199352d954bb4bb5f7572da0a75519177f17643e",
        "ota/errors.js": "336cd4e51521cd481ccfb8e58d448ca32a4ec879054fa253d1bb96a17578ba99",
        "ota/lz4raw-aarch64.so": "1ee6ed4929b19be39e607e9bcfb48a3402a7008ced54bf74e34071596d900bde",
        "ota/mu300/engine.py": "a1ffea745a6e664547a7a3495bdaac5f2eafcd8f497d31fd432446a4fa9f7255",
        "ota/proxy.sh": "80839c4e52bd251c027e6c409a46c52c478acb6311a7720945b49fa5ca5db327",
        "ota/rpc.py": "296301376786c881766ca80aef7f6f1482444fa6fb58d3e0b35f17237de299a5",
        "ota/unisoc-ota.js": "e4252e6f1c5727053d61d2759f395c9c076ed559d8ca4cc730d3288a875d50dc",
        "ota/unisoc-ota.json": "696a533e918368dcf009855b76fa9388ff3311656abc161a12cbaf5564a04c42",
    ]

    func testBundledAssetsMatchAndroid() throws {
        XCTAssertEqual(Self.expectedAssetHashes.count, 28, "asset manifest must cover every file")
        let bundle = Bundle.main
        for (relativePath, expected) in Self.expectedAssetHashes {
            guard let url = bundle.url(forResource: relativePath, withExtension: nil, subdirectory: "Assets") ??
                    bundle.resourceURL?.appendingPathComponent("Assets/" + relativePath) else {
                return XCTFail("missing bundled asset: \(relativePath)")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing bundled asset: \(relativePath)")
            let data = try Data(contentsOf: url)
            XCTAssertEqual(Py.sha256Hex(data), expected, "hash mismatch for \(relativePath)")
        }
    }
}
