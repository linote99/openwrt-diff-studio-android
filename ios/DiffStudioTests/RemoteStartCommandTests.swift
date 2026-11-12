// RemoteStartCommandTests.swift
// Port of com.linote.diffstudio.ssh.RemoteStartCommandTest (JUnit, Java).

import XCTest
@testable import DiffStudio

final class RemoteStartCommandTests: XCTestCase {
    func testStartUsesReviewedPatchIdInsteadOfRandomRuntimeId() throws {
        let runtimeId = String(repeating: "a", count: 64)
        let reviewedPatchId = String(repeating: "b", count: 64)
        let stagedPatchId = String(repeating: "c", count: 64)
        let home = "/tmp/unisoc-ota-" + runtimeId
        let path = "/etc/unisoc-ota/upload-" + stagedPatchId + ".ota"

        var check = JsonObject()
        check.put("id", .string(reviewedPatchId))
        var session = JsonObject()
        session.put("runtime", .string(home))
        session.put("path", .string(path))
        session.put("check", .object(check))

        let command = try Remote.runtimeStartCommand(session)
        guard let rpcRange = command.range(of: "/ota/rpc.py start ") else {
            return XCTFail("start command does not contain rpc.py start")
        }
        let rpc = String(command[rpcRange.lowerBound...])
        XCTAssertEqual(rpc, "/ota/rpc.py start " + Remote.q("/target" + path) + " " + Remote.q(reviewedPatchId))
        XCTAssertTrue(command.contains(Remote.q(home + "/bootstrap.sh") + " " + Remote.q(path) + " inspect "))
    }

    func testStartRejectsMissingReviewedPatchId() {
        var session = JsonObject()
        session.put("runtime", .string("/tmp/unisoc-ota-" + String(repeating: "a", count: 64)))
        session.put("path", .string("/etc/unisoc-ota/upload-" + String(repeating: "b", count: 64) + ".ota"))
        session.put("check", .object(JsonObject()))

        XCTAssertThrowsError(try Remote.runtimeStartCommand(session)) { error in
            XCTAssertTrue(error is OtaError)
        }
    }
}
