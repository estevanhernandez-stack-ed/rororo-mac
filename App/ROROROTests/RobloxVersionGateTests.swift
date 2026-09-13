// RobloxVersionGateTests.swift
// Covers the stale-Roblox preflight: pure verdict compare, live-version
// wire decode, local Info.plist read against a fake bundle, and the
// fail-open behaviour when the version endpoint is unreachable.
//
// Background (support case 2026-09-13): when /Applications/Roblox.app is
// behind Roblox's live MacPlayer version, every per-instance copy spawns
// its embedded RobloxPlayerInstaller. The installer holds a per-user
// flock at $TMPDIR/com.roblox.player.installer.lock; the second copy's
// installer fails on that lock with "Another Installer is already
// running." and the first installer relaunches the canonical
// /Applications/Roblox.app — not the per-instance copy — so the account
// identity is lost too. The gate refuses the copy step while Roblox is
// stale so the user gets an actionable message instead of that dialog.

import XCTest
@testable import RORORO

final class RobloxVersionGateTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("rororo-version-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        RobloxVersionGate.urlSessionForTesting = URLSession(configuration: config)
        URLProtocolStub.reset()
    }

    override func tearDown() async throws {
        URLProtocolStub.reset()
        RobloxVersionGate.urlSessionForTesting = nil
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        try await super.tearDown()
    }

    // MARK: - Pure verdict

    func testVerdict_SameVersion_IsCurrent() {
        let verdict = RobloxVersionGate.verdict(local: "0.738.0.7381393", live: "0.738.0.7381393")
        XCTAssertEqual(verdict, .current)
    }

    func testVerdict_DifferentVersion_IsStale() {
        let verdict = RobloxVersionGate.verdict(local: "0.726.0.7261140", live: "0.738.0.7381393")
        XCTAssertEqual(verdict, .stale(local: "0.726.0.7261140", live: "0.738.0.7381393"))
    }

    func testVerdict_MissingLive_IsUnknown() {
        // Fail open: no network → don't block launches.
        XCTAssertEqual(RobloxVersionGate.verdict(local: "0.726.0.7261140", live: nil), .unknown)
    }

    func testVerdict_MissingLocal_IsUnknown() {
        // Roblox not installed is RobloxAppCopier.sourceMissing's job to
        // report; the gate stays out of the way.
        XCTAssertEqual(RobloxVersionGate.verdict(local: nil, live: "0.738.0.7381393"), .unknown)
    }

    // MARK: - Wire decode

    func testLiveVersionResponse_DecodesClientSettingsShape() throws {
        let json = """
        {"version":"0.738.0.7381393","clientVersionUpload":"version-5b15515e80624095","bootstrapperVersion":""}
        """.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(RobloxVersionGate.LiveVersionResponse.self, from: json)
        XCTAssertEqual(parsed.version, "0.738.0.7381393")
        XCTAssertEqual(parsed.clientVersionUpload, "version-5b15515e80624095")
    }

    // MARK: - Local read

    func testLocalVersion_ReadsShortVersionFromBundlePlist() throws {
        let app = try makeFakeApp(version: "0.726.0.7261140")
        XCTAssertEqual(RobloxVersionGate.localVersion(appPath: app.path), "0.726.0.7261140")
    }

    func testLocalVersion_MissingBundle_ReturnsNil() {
        let missing = tempRoot.appendingPathComponent("Nope.app").path
        XCTAssertNil(RobloxVersionGate.localVersion(appPath: missing))
    }

    // MARK: - Preflight end-to-end (stubbed network)

    func testPreflight_StaleLocal_ReturnsStale() async throws {
        let app = try makeFakeApp(version: "0.726.0.7261140")
        URLProtocolStub.enqueue(
            status: 200,
            body: #"{"version":"0.738.0.7381393","clientVersionUpload":"version-abc"}"#.data(using: .utf8)
        )
        let gate = RobloxVersionGate(appPath: app.path)
        let verdict = await gate.preflight()
        XCTAssertEqual(verdict, .stale(local: "0.726.0.7261140", live: "0.738.0.7381393"))
    }

    func testPreflight_CurrentLocal_ReturnsCurrent() async throws {
        let app = try makeFakeApp(version: "0.738.0.7381393")
        URLProtocolStub.enqueue(
            status: 200,
            body: #"{"version":"0.738.0.7381393","clientVersionUpload":"version-abc"}"#.data(using: .utf8)
        )
        let gate = RobloxVersionGate(appPath: app.path)
        let verdict = await gate.preflight()
        XCTAssertEqual(verdict, .current)
    }

    func testPreflight_EndpointDown_FailsOpenAsUnknown() async throws {
        let app = try makeFakeApp(version: "0.726.0.7261140")
        URLProtocolStub.enqueue(status: 503, body: nil)
        let gate = RobloxVersionGate(appPath: app.path)
        let verdict = await gate.preflight()
        XCTAssertEqual(verdict, .unknown)
    }

    func testPreflight_CachesLiveVersionWithinTTL() async throws {
        let app = try makeFakeApp(version: "0.738.0.7381393")
        URLProtocolStub.enqueue(
            status: 200,
            body: #"{"version":"0.738.0.7381393","clientVersionUpload":"version-abc"}"#.data(using: .utf8)
        )
        let gate = RobloxVersionGate(appPath: app.path, cacheTTL: 300)
        _ = await gate.preflight()
        _ = await gate.preflight()
        XCTAssertEqual(URLProtocolStub.capturedRequests.count, 1,
                       "second preflight inside the TTL must not hit the network")
    }

    // MARK: - Message

    func testStaleMessage_NamesBothVersionsAndTheFix() {
        let verdict = RobloxVersionGate.Verdict.stale(local: "0.726.0.7261140", live: "0.738.0.7381393")
        let message = verdict.userMessage
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("0.726.0.7261140"))
        XCTAssertTrue(message!.contains("0.738.0.7381393"))
        XCTAssertTrue(message!.lowercased().contains("open roblox"),
                      "message must tell the user the one action that fixes it")
        XCTAssertNil(RobloxVersionGate.Verdict.current.userMessage)
        XCTAssertNil(RobloxVersionGate.Verdict.unknown.userMessage)
    }

    // MARK: - Fixture

    private func makeFakeApp(version: String) throws -> URL {
        let app = tempRoot.appendingPathComponent("FakeRoblox-\(UUID().uuidString).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.roblox.RobloxPlayer",
            "CFBundleShortVersionString": version,
            "LSMultipleInstancesProhibited": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }
}
