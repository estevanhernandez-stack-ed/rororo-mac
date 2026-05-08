// ClientSettingsWriterTests.swift
// Atomic JSON writes + hand-edit detection for ClientAppSettings.json.
// Tests use an in-memory bundle resolver so the user's real Roblox.app
// never gets touched.

import XCTest
@testable import RORORO

final class ClientSettingsWriterTests: XCTestCase {

    private var tempDir: URL!
    private var fakeSettingsURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rororo-clientsettings-\(UUID().uuidString)", isDirectory: true)
        fakeSettingsURL = tempDir
            .appendingPathComponent("Contents/MacOS/ClientSettings/ClientAppSettings.json")
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    private func resolver() -> URL? { fakeSettingsURL }

    // MARK: - Basic write

    func testWrite_CreatesFileAndIntermediateDirs() throws {
        let outcome = try ClientSettingsWriter.write(
            flags: ["FFlagDebugGraphicsPreferMetal": true],
            bundleResolver: resolver
        )

        XCTAssertEqual(outcome, .createdFresh)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fakeSettingsURL.path))
    }

    func testWrite_PreservesValueTypes() throws {
        let flags: [String: Any] = [
            "FFlagBool": true,
            "DFIntInt": 5,
            "FStringString": "hello",
        ]

        try ClientSettingsWriter.write(flags: flags, bundleResolver: resolver)

        let data = try Data(contentsOf: fakeSettingsURL)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(decoded?["FFlagBool"] as? Bool, true)
        XCTAssertEqual(decoded?["DFIntInt"] as? Int, 5)
        XCTAssertEqual(decoded?["FStringString"] as? String, "hello")
    }

    func testWrite_ThrowsWhenBundleNotFound() {
        XCTAssertThrowsError(
            try ClientSettingsWriter.write(flags: [:], bundleResolver: { nil })
        ) { error in
            guard case ClientSettingsWriter.WriterError.bundleNotFound = error else {
                return XCTFail("expected bundleNotFound, got \(error)")
            }
        }
    }

    // MARK: - Hand-edit detection

    func testWrite_DetectsOurOwnFileOnSecondWrite() throws {
        let outcome1 = try ClientSettingsWriter.write(
            flags: ["FFlagA": true],
            bundleResolver: resolver
        )
        XCTAssertEqual(outcome1, .createdFresh)

        let outcome2 = try ClientSettingsWriter.write(
            flags: ["FFlagA": true],
            bundleResolver: resolver
        )
        XCTAssertEqual(outcome2, .overwroteOurOwn)
    }

    func testWrite_DetectsUserHandEditWhenContentDiverges() throws {
        try ClientSettingsWriter.write(flags: ["FFlagA": true], bundleResolver: resolver)

        // User hand-edits behind our back — different content, hash mismatches.
        try Data("{\"FFlagUserEdit\":true}".utf8).write(to: fakeSettingsURL)

        let outcome = try ClientSettingsWriter.write(
            flags: ["FFlagA": true],
            policy: .stomp,
            bundleResolver: resolver
        )

        XCTAssertEqual(outcome, .stompedUserEdit)
    }

    func testWrite_PreservePolicyThrowsOnHandEdit() throws {
        try ClientSettingsWriter.write(flags: ["FFlagA": true], bundleResolver: resolver)
        try Data("{\"FFlagUserEdit\":true}".utf8).write(to: fakeSettingsURL)

        XCTAssertThrowsError(
            try ClientSettingsWriter.write(
                flags: ["FFlagA": true],
                policy: .preserveAndThrow,
                bundleResolver: resolver
            )
        ) { error in
            guard case ClientSettingsWriter.WriterError.writeFailed = error else {
                return XCTFail("expected writeFailed, got \(error)")
            }
        }
    }

    // MARK: - Cleanup

    func testCleanup_RemovesFileWeWrote() throws {
        try ClientSettingsWriter.write(flags: ["FFlagA": true], bundleResolver: resolver)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fakeSettingsURL.path))

        try ClientSettingsWriter.cleanup(bundleResolver: resolver)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fakeSettingsURL.path))
    }

    func testCleanup_NoOpWhenFileAbsent() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: fakeSettingsURL.path))
        XCTAssertNoThrow(try ClientSettingsWriter.cleanup(bundleResolver: resolver))
    }
}
