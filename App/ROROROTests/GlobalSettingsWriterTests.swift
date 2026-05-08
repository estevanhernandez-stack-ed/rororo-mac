// GlobalSettingsWriterTests.swift
// Surgical XML edits to GlobalBasicSettings_<N>.xml.
// Tests use a per-test temp directory so the user's real
// ~/Library/Roblox/ never gets touched.

import XCTest
@testable import RORORO

final class GlobalSettingsWriterTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rororo-gbs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    // MARK: - resolveSettingsFile

    func testResolve_PicksHighestVersionWhenMultiplePresent() throws {
        try writeSettingsFile(version: 11, framerateCap: 60)
        try writeSettingsFile(version: 13, framerateCap: 60)
        try writeSettingsFile(version: 12, framerateCap: 60)

        let resolved = GlobalSettingsWriter.resolveSettingsFile(in: tempDir)

        XCTAssertEqual(resolved?.lastPathComponent, "GlobalBasicSettings_13.xml")
    }

    func testResolve_ReturnsNilWhenDirectoryEmpty() {
        let resolved = GlobalSettingsWriter.resolveSettingsFile(in: tempDir)
        XCTAssertNil(resolved)
    }

    func testResolve_IgnoresUnrelatedFiles() throws {
        try "<roblox/>".write(
            to: tempDir.appendingPathComponent("OtherFile.xml"),
            atomically: true,
            encoding: .utf8
        )
        try writeSettingsFile(version: 13, framerateCap: 60)

        let resolved = GlobalSettingsWriter.resolveSettingsFile(in: tempDir)

        XCTAssertEqual(resolved?.lastPathComponent, "GlobalBasicSettings_13.xml")
    }

    // MARK: - currentFramerateCap

    func testCurrentFramerateCap_ReadsExistingValue() throws {
        try writeSettingsFile(version: 13, framerateCap: 144)

        let value = try GlobalSettingsWriter.currentFramerateCap(directory: tempDir)

        XCTAssertEqual(value, 144)
    }

    func testCurrentFramerateCap_ThrowsWhenNoFile() {
        XCTAssertThrowsError(
            try GlobalSettingsWriter.currentFramerateCap(directory: tempDir)
        ) { error in
            guard case GlobalSettingsWriter.WriterError.settingsFileNotFound = error else {
                return XCTFail("expected settingsFileNotFound, got \(error)")
            }
        }
    }

    // MARK: - setFramerateCap

    func testSetFramerateCap_WritesNewValueAndPreservesEverythingElse() throws {
        try writeSettingsFile(version: 13, framerateCap: 60)

        try GlobalSettingsWriter.setFramerateCap(20, directory: tempDir)

        let updated = try GlobalSettingsWriter.currentFramerateCap(directory: tempDir)
        XCTAssertEqual(updated, 20)

        // Confirm sibling elements are untouched.
        let url = GlobalSettingsWriter.resolveSettingsFile(in: tempDir)!
        let raw = try String(contentsOf: url)
        XCTAssertTrue(raw.contains(#"<int name="GraphicsQualityLevel">3</int>"#))
        XCTAssertTrue(raw.contains(#"<bool name="Fullscreen">false</bool>"#))
        XCTAssertTrue(raw.contains(#"<float name="MouseSensitivity">1</float>"#))
    }

    func testSetFramerateCap_AcceptsLowAndHighValues() throws {
        // Multi-instance throttle — the headline use case.
        try writeSettingsFile(version: 13, framerateCap: 60)
        try GlobalSettingsWriter.setFramerateCap(20, directory: tempDir)
        XCTAssertEqual(try GlobalSettingsWriter.currentFramerateCap(directory: tempDir), 20)

        // Unlock — same property, opposite direction (Windows recipe).
        try GlobalSettingsWriter.setFramerateCap(9999, directory: tempDir)
        XCTAssertEqual(try GlobalSettingsWriter.currentFramerateCap(directory: tempDir), 9999)
    }

    func testSetFramerateCap_ThrowsWhenElementMissing() throws {
        try writeSettingsFile(version: 13, framerateCap: nil)

        XCTAssertThrowsError(
            try GlobalSettingsWriter.setFramerateCap(20, directory: tempDir)
        ) { error in
            guard case GlobalSettingsWriter.WriterError.framerateCapElementMissing = error else {
                return XCTFail("expected framerateCapElementMissing, got \(error)")
            }
        }
    }

    func testSetFramerateCap_RoundTripPreservesRobloxRootAttributes() throws {
        try writeSettingsFile(version: 13, framerateCap: 60)
        let url = GlobalSettingsWriter.resolveSettingsFile(in: tempDir)!
        let before = try String(contentsOf: url)

        try GlobalSettingsWriter.setFramerateCap(30, directory: tempDir)

        let after = try String(contentsOf: url)
        // <roblox> root attributes (xmlns, version) survive.
        XCTAssertTrue(after.contains(#"xmlns:xmime="http://www.w3.org/2005/05/xmlmime""#))
        XCTAssertTrue(after.contains(#"version="4""#))
        // Prove the FramerateCap line actually changed (not just no-op).
        XCTAssertNotEqual(before, after)
    }

    // MARK: - Fixtures

    private func writeSettingsFile(version: Int, framerateCap: Int?) throws {
        let cap: String
        if let framerateCap {
            cap = "<int name=\"FramerateCap\">\(framerateCap)</int>"
        } else {
            cap = "" // simulate the (rare) corrupted case where the element is absent
        }
        let xml = """
        <roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">
            <External>null</External>
            <Item class="UserGameSettings" referent="RBX-test">
                <Properties>
                    <bool name="Fullscreen">false</bool>
                    \(cap)
                    <int name="GraphicsQualityLevel">3</int>
                    <float name="MouseSensitivity">1</float>
                </Properties>
            </Item>
        </roblox>
        """
        let url = tempDir.appendingPathComponent("GlobalBasicSettings_\(version).xml")
        try xml.write(to: url, atomically: true, encoding: .utf8)
    }
}
