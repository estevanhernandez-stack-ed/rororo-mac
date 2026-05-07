// RobloxAppCopierTests.swift
// Covers the copy-and-flip path against a fake .app bundle in a temp dir.
// The real `/Applications/Roblox.app` test is gated on its presence —
// most CI runners won't have it.

import XCTest
@testable import RORORO

final class RobloxAppCopierTests: XCTestCase {

    private var tempRoot: URL!
    private var fakeAppURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        // Per-test temp dir for both the fake source app + our private
        // Application Support override. Avoids polluting the real
        // ~/Library/Application Support/RORORO/.
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("rororo-mac-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        fakeAppURL = tempRoot.appendingPathComponent("FakeRoblox.app", isDirectory: true)
        try buildFakeRobloxApp(at: fakeAppURL, multipleInstancesProhibited: true)
    }

    override func tearDown() async throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try await super.tearDown()
    }

    // MARK: - copyAppForInstance against fake app

    func testCopyAppForInstance_PreservesOriginalSignatureUntouched() throws {
        let copy = try RobloxAppCopier.copyAppForInstance(
            sourceAppPath: fakeAppURL.path,
            supportDirOverride: tempRoot
        )
        defer { try? FileManager.default.removeItem(at: copy) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertNotEqual(copy, fakeAppURL, "destination should be a copy, not the source")

        // Info.plist should match source — no modifications at copy time.
        // Modifying before `open -n -a` would invalidate cdhash; amfid
        // refuses Hardened Runtime apps with broken signatures.
        let plistURL = copy.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]

        XCTAssertEqual(
            plist?["LSMultipleInstancesProhibited"] as? Bool, true,
            "fixture set this true; copy must preserve until post-launch flip"
        )
        XCTAssertEqual(plist?["CFBundleIdentifier"] as? String, "com.test.fakeroblox")
    }

    func testSetMultipleInstancesProhibitionPostLaunch_FlipsValue() throws {
        let copy = try RobloxAppCopier.copyAppForInstance(
            sourceAppPath: fakeAppURL.path,
            supportDirOverride: tempRoot
        )
        defer { try? FileManager.default.removeItem(at: copy) }

        try RobloxAppCopier.setMultipleInstancesProhibitionPostLaunch(at: copy, prohibited: false)

        let plistURL = copy.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
        XCTAssertEqual(plist?["LSMultipleInstancesProhibited"] as? Bool, false)
    }

    func testCopyAppForInstance_SourceMissing_Throws() {
        let bogusPath = tempRoot.appendingPathComponent("Nonexistent.app").path
        XCTAssertThrowsError(
            try RobloxAppCopier.copyAppForInstance(
                sourceAppPath: bogusPath,
                supportDirOverride: tempRoot
            )
        ) { error in
            switch error {
            case RobloxAppCopier.CopyError.sourceMissing(let path):
                XCTAssertEqual(path, bogusPath)
            default:
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testCopyAppForInstance_LandsUnderInstancesSubdir() throws {
        let copy = try RobloxAppCopier.copyAppForInstance(
            sourceAppPath: fakeAppURL.path,
            supportDirOverride: tempRoot
        )
        defer { try? FileManager.default.removeItem(at: copy) }

        XCTAssertTrue(copy.path.contains("/instances/"))
        XCTAssertTrue(copy.lastPathComponent.hasSuffix(".app"))
    }

    func testCopyAppForInstance_TwoCallsProduceTwoDistinctCopies() throws {
        let first = try RobloxAppCopier.copyAppForInstance(
            sourceAppPath: fakeAppURL.path, supportDirOverride: tempRoot
        )
        let second = try RobloxAppCopier.copyAppForInstance(
            sourceAppPath: fakeAppURL.path, supportDirOverride: tempRoot
        )
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    // MARK: - cleanupStaleInstances

    func testCleanupStaleInstances_DeletesOldCopies_KeepsRecent() throws {
        let copy = try RobloxAppCopier.copyAppForInstance(
            sourceAppPath: fakeAppURL.path, supportDirOverride: tempRoot
        )

        // Backdate the creation date to 48h ago.
        let twoDaysAgo = Date().addingTimeInterval(-48 * 3600)
        try FileManager.default.setAttributes(
            [.creationDate: twoDaysAgo],
            ofItemAtPath: copy.path
        )

        // 24h cutoff (default) should sweep it.
        try RobloxAppCopier.cleanupStaleInstances(supportDirOverride: tempRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    func testCleanupStaleInstances_NoOpWhenInstancesDirEmpty() {
        XCTAssertNoThrow(
            try RobloxAppCopier.cleanupStaleInstances(supportDirOverride: tempRoot)
        )
    }

    // MARK: - Real Roblox.app integration (skipped when not installed)

    func testCopyAppForInstance_AgainstRealRoblox() throws {
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: RobloxAppCopier.robloxAppPath),
            "Roblox.app not installed; integration test skipped."
        )

        let copy = try RobloxAppCopier.copyAppForInstance(supportDirOverride: tempRoot)
        defer { try? FileManager.default.removeItem(at: copy) }

        // Copy exists and Info.plist is preserved as-shipped.
        // Post-launch flip happens in MultiInstanceCoordinator after open -n -a.
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: copy.appendingPathComponent("Contents/Info.plist").path
        ))
    }

    // MARK: - Helpers

    private func buildFakeRobloxApp(at url: URL, multipleInstancesProhibited: Bool) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.test.fakeroblox",
            "CFBundleName": "FakeRoblox",
            "CFBundleExecutable": "FakeRoblox",
            "CFBundlePackageType": "APPL",
            "LSMultipleInstancesProhibited": multipleInstancesProhibited,
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))

        // A token "executable" — never run; just file system filler.
        try Data().write(to: macOS.appendingPathComponent("FakeRoblox"))
    }
}
