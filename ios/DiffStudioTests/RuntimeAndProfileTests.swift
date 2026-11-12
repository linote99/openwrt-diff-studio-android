// RuntimeAndProfileTests.swift
// Port of com.linote.diffstudio.core.RuntimeAndProfileTest (JUnit, Java).

import XCTest
@testable import DiffStudio

final class RuntimeAndProfileTests: XCTestCase {
    private func meta(_ profile: String, _ imageVersion: String) -> JsonObject {
        var value = JsonObject()
        value.put("profile", .string(profile))
        value.put("image_version", .string(imageVersion))
        value.put("openwrt", .string("25.12.5"))
        value.put("kernel_release", .string("6.12.94-u30pro-p1"))
        return value
    }

    func testPatchFilenameUsesUpstreamNativeProfileLabels() {
        let old = meta("f50pro", "r20261001.000000-g1234567890")
        let f50 = meta("f50pro", "r20261106.144559-g0696fbc2")
        let u30 = meta("u30pro", "r20261106.144559-g0696fbc2")
        let lym = meta("lym10k", "r20261106.144559-g0696fbc2")

        XCTAssertTrue(OtaPackage.patchFilename(old: old, neu: f50, source: "new.zip").contains("-F50Pro-"))
        XCTAssertTrue(OtaPackage.patchFilename(old: old, neu: u30, source: "new.zip").contains("-U30Pro-"))
        XCTAssertTrue(OtaPackage.patchFilename(old: old, neu: lym, source: "new.zip").contains("-LYM-10K-"))
    }

    func testGeneratedBootstrapSeparatesSessionIdFromReviewedPatchId() {
        let script = String(decoding: OtaRuntime.bootstrap(OrderedMap<String, JsonObject>()), as: UTF8.self)

        XCTAssertTrue(script.contains("session=${home#/tmp/unisoc-ota-}"))
        XCTAssertTrue(script.contains("id=${4:-}"))
        XCTAssertTrue(script.contains("upload-*.ota"))
        XCTAssertTrue(script.contains("reviewed-*.ota"))
        XCTAssertTrue(script.contains("/ota/rpc.py start \"/target$patch\" \"$id\""))
        XCTAssertFalse(script.contains("id=${home#/tmp/unisoc-ota-}"))
    }
}
