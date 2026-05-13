// RobloxAppCopierTests.swift
// Covers the copy-and-flip path against a fake .app bundle in a temp dir.
// The real `/Applications/Roblox.app` test is gated on its presence —
// most CI runners won't have it.

import XCTest
@testable import RORORO

final class RobloxAppCopierTests: XCTestCase {

    private var tempRoot: URL!
    private var fakeAppURL: URL!
    private var entitlementsURL: URL!

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

        // Test entitlements file with disable-library-validation. The
        // production path resolves entitlements via Bundle.main (the host
        // RORORO.app). Tests override to a temp path to keep the test
        // self-contained even if the resource fails to bundle in dev
        // builds. Ad-hoc identity (`-`) avoids requiring a Developer ID
        // cert in the test runner's keychain.
        entitlementsURL = tempRoot.appendingPathComponent("test-relax-libval.plist")
        let entitlementsXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.security.cs.disable-library-validation</key>
            <true/>
        </dict>
        </plist>
        """
        try entitlementsXML.write(to: entitlementsURL, atomically: true, encoding: .utf8)
    }

    /// Helper — calls copyAppForInstance with the fake source + ad-hoc
    /// signing + the test entitlements path. Keeps individual tests from
    /// repeating the same 5 named args every call.
    private func copyForTest(bundleLabel: String? = nil) throws -> URL {
        return try RobloxAppCopier.copyAppForInstance(
            sourceAppPath: fakeAppURL.path,
            supportDirOverride: tempRoot,
            bundleLabel: bundleLabel,
            signingIdentity: "-",
            entitlementsPath: entitlementsURL.path
        )
    }

    override func tearDown() async throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try await super.tearDown()
    }

    // MARK: - copyAppForInstance against fake app

    func testCopyAppForInstance_RewritesBundleIDAndFlipsMultiInstance() throws {
        let copy = try copyForTest()
        defer { try? FileManager.default.removeItem(at: copy) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertNotEqual(copy, fakeAppURL, "destination should be a copy, not the source")

        // Info.plist is rewritten in-place by BundleIDRewriter: unique
        // bundle ID for per-instance storage isolation + multi-instance
        // flag flipped off. cdhash refreshed by the re-sign in the same
        // pass — amfid accepts the new signature on launch.
        let plistURL = copy.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]

        XCTAssertEqual(
            plist?["LSMultipleInstancesProhibited"] as? Bool, false,
            "rewrite must flip the multi-instance flag off in the same pass"
        )
        let rewrittenID = plist?["CFBundleIdentifier"] as? String ?? ""
        XCTAssertTrue(
            rewrittenID.hasPrefix("com.626labs.RORORO.instance."),
            "expected per-instance bundle ID prefix, got: \(rewrittenID)"
        )
        XCTAssertNotEqual(rewrittenID, "com.test.fakeroblox",
                          "rewrite must replace the source bundle ID")
    }

    func testCopyAppForInstance_TwoCallsProduceDistinctBundleIDs() throws {
        let firstCopy = try copyForTest()
        let secondCopy = try copyForTest()
        defer {
            try? FileManager.default.removeItem(at: firstCopy)
            try? FileManager.default.removeItem(at: secondCopy)
        }
        let firstID = try bundleID(at: firstCopy)
        let secondID = try bundleID(at: secondCopy)
        XCTAssertNotEqual(firstID, secondID, "each copy must get its own unique bundle ID")
    }

    private func bundleID(at appURL: URL) throws -> String {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
        return (plist?["CFBundleIdentifier"] as? String) ?? ""
    }

    func testCopyAppForInstance_SourceMissing_Throws() {
        let bogusPath = tempRoot.appendingPathComponent("Nonexistent.app").path
        XCTAssertThrowsError(
            try RobloxAppCopier.copyAppForInstance(
                sourceAppPath: bogusPath,
                supportDirOverride: tempRoot,
                signingIdentity: "-",
                entitlementsPath: entitlementsURL.path
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
        let copy = try copyForTest()
        defer { try? FileManager.default.removeItem(at: copy) }

        XCTAssertTrue(copy.path.contains("/instances/"))
        XCTAssertTrue(copy.lastPathComponent.hasSuffix(".app"))
    }

    func testCopyAppForInstance_DefaultsBundleNameToRobloxApp() throws {
        // Per the Dock-name fix: each per-launch copy lives at
        // `instances/<UUID>/<label>.app/`. With no `bundleLabel`
        // argument the label falls back to "Roblox", so the bundle
        // is `Roblox.app` — Dock shows "Roblox" for that instance.
        let copy = try copyForTest()
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }

        XCTAssertEqual(copy.lastPathComponent, "Roblox.app")
        XCTAssertTrue(copy.deletingLastPathComponent().path.contains("/instances/"))
    }

    func testCopyAppForInstance_NamesBundleAfterPlayerWhenLabelProvided() throws {
        // Player-named bundles surface in the Dock per launch. Caller
        // (RobloxLauncher) passes the launching account's display name.
        let copy = try copyForTest(bundleLabel: "Estevan")
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }

        XCTAssertEqual(copy.lastPathComponent, "Estevan.app")
    }

    // MARK: - sanitizedBundleLabel

    // MARK: - makePerInstanceBundleID (stable-per-account derivation)

    func testMakePerInstanceBundleID_NilSlug_FallsBackToUUID() {
        let a = RobloxAppCopier.makePerInstanceBundleID(accountSlug: nil)
        let b = RobloxAppCopier.makePerInstanceBundleID(accountSlug: nil)
        XCTAssertNotEqual(a, b, "nil slug must produce a fresh UUID-keyed ID each call")
        XCTAssertTrue(a.hasPrefix("com.626labs.RORORO.instance."))
        XCTAssertTrue(b.hasPrefix("com.626labs.RORORO.instance."))
        XCTAssertFalse(a.contains(".uid"), "UUID fallback shouldn't carry the 'uid' marker")
    }

    func testMakePerInstanceBundleID_StableSlug_DeterministicAcrossCalls() {
        let a = RobloxAppCopier.makePerInstanceBundleID(accountSlug: "12345")
        let b = RobloxAppCopier.makePerInstanceBundleID(accountSlug: "12345")
        XCTAssertEqual(a, b, "same slug must produce the same bundle ID — TCC + tracker rely on this")
        XCTAssertEqual(a, "com.626labs.RORORO.instance.uid12345")
    }

    func testMakePerInstanceBundleID_DifferentSlugs_ProduceDifferentIDs() {
        let a = RobloxAppCopier.makePerInstanceBundleID(accountSlug: "12345")
        let b = RobloxAppCopier.makePerInstanceBundleID(accountSlug: "67890")
        XCTAssertNotEqual(a, b)
    }

    func testMakePerInstanceBundleID_SlugSanitizesUnsafeChars() {
        // Spaces, underscores, slashes, capitals — all get folded to
        // the safe [a-z0-9-] subset for reverse-DNS bundle IDs.
        let id = RobloxAppCopier.makePerInstanceBundleID(accountSlug: "User 42_Test/Beta")
        XCTAssertTrue(id.hasPrefix("com.626labs.RORORO.instance.uid"),
                      "expected uid-prefixed bundle ID, got: \(id)")
        // No uppercase, no underscores, no slashes, no spaces past the prefix.
        let suffix = String(id.dropFirst("com.626labs.RORORO.instance.".count))
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        for ch in suffix {
            XCTAssertTrue(allowed.contains(ch),
                          "suffix \(suffix) contained disallowed char \(ch)")
        }
    }

    func testMakePerInstanceBundleID_EmptySlug_FallsBackToUUID() {
        let id = RobloxAppCopier.makePerInstanceBundleID(accountSlug: "")
        XCTAssertTrue(id.hasPrefix("com.626labs.RORORO.instance."))
        XCTAssertFalse(id.contains(".uid"),
                       "empty-string slug should not produce a uid-keyed ID")
    }

    func testMakePerInstanceBundleID_AllInvalidChars_FallsBackToUUID() {
        // If sanitization strips everything (e.g., a slug of only "/!@#"),
        // we don't want a bare "com.626labs.RORORO.instance.uid" — fall
        // back to UUID so we still produce a unique ID.
        let id = RobloxAppCopier.makePerInstanceBundleID(accountSlug: "/!@#")
        XCTAssertFalse(id.contains(".uid"),
                       "all-invalid slug should fall back to UUID, got: \(id)")
        XCTAssertTrue(id.hasPrefix("com.626labs.RORORO.instance."))
    }

    func testCopyAppForInstance_SameSlug_ProducesSameBundleIDAcrossCopies() throws {
        // Stable-per-account contract: relaunching the same account
        // must reuse the same bundle ID so macOS keeps the TCC grants
        // attached and the cookie jar / preferences plist persist.
        let first = try RobloxAppCopier.copyAppForInstance(
            sourceAppPath: fakeAppURL.path,
            supportDirOverride: tempRoot,
            accountSlug: "stable-test-12345",
            signingIdentity: "-",
            entitlementsPath: entitlementsURL.path
        )
        let second = try RobloxAppCopier.copyAppForInstance(
            sourceAppPath: fakeAppURL.path,
            supportDirOverride: tempRoot,
            accountSlug: "stable-test-12345",
            signingIdentity: "-",
            entitlementsPath: entitlementsURL.path
        )
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        XCTAssertEqual(try bundleID(at: first), try bundleID(at: second))
        XCTAssertEqual(try bundleID(at: first),
                       "com.626labs.RORORO.instance.uidstable-test-12345")
    }

    // MARK: - sanitizedBundleLabel

    func testSanitizedBundleLabel_PassesThroughCleanNames() {
        XCTAssertEqual(RobloxAppCopier.sanitizedBundleLabel(from: "Estevan"), "Estevan")
        XCTAssertEqual(RobloxAppCopier.sanitizedBundleLabel(from: "Liz Lemon"), "Liz Lemon")
        XCTAssertEqual(RobloxAppCopier.sanitizedBundleLabel(from: "alt_42"), "alt_42")
    }

    func testSanitizedBundleLabel_ReplacesForbiddenPathChars() {
        XCTAssertEqual(RobloxAppCopier.sanitizedBundleLabel(from: "a/b"), "a-b")
        XCTAssertEqual(RobloxAppCopier.sanitizedBundleLabel(from: "x:y"), "x-y")
    }

    func testSanitizedBundleLabel_FallsBackToRobloxOnEmptyOrNil() {
        XCTAssertEqual(RobloxAppCopier.sanitizedBundleLabel(from: nil), "Roblox")
        XCTAssertEqual(RobloxAppCopier.sanitizedBundleLabel(from: ""), "Roblox")
        XCTAssertEqual(RobloxAppCopier.sanitizedBundleLabel(from: "   "), "Roblox")
    }

    func testSanitizedBundleLabel_CapsLengthSoDockDoesntTruncateMid() {
        let long = String(repeating: "x", count: 100)
        let sanitized = RobloxAppCopier.sanitizedBundleLabel(from: long)
        XCTAssertLessThanOrEqual(sanitized.count, 48)
    }

    func testCopyAppForInstance_TwoCallsProduceTwoDistinctCopies() throws {
        let first = try copyForTest()
        let second = try copyForTest()
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
        let copy = try copyForTest()

        // The cleanup iterates entries directly under instances/, which
        // are now the UUID parent dirs (not the .app bundles themselves).
        // Backdate the parent so the cleanup sweep catches it.
        let parentDir = copy.deletingLastPathComponent()
        let twoDaysAgo = Date().addingTimeInterval(-48 * 3600)
        try FileManager.default.setAttributes(
            [.creationDate: twoDaysAgo],
            ofItemAtPath: parentDir.path
        )

        // 24h cutoff (default) should sweep the whole parent dir.
        try RobloxAppCopier.cleanupStaleInstances(supportDirOverride: tempRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parentDir.path))
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

        // Ad-hoc signing so the test passes on any keychain. End-to-end
        // launch validation (with the real Developer ID identity) lives
        // in the manual smoke matrix in the plan, not here.
        let copy = try RobloxAppCopier.copyAppForInstance(
            supportDirOverride: tempRoot,
            signingIdentity: "-",
            entitlementsPath: entitlementsURL.path
        )
        defer { try? FileManager.default.removeItem(at: copy) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        let plistURL = copy.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plistURL.path))

        // Real Roblox.app bundle ID becomes our per-instance ID after
        // rewrite. cdhash is fresh from the re-sign.
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
        let rewrittenID = (plist?["CFBundleIdentifier"] as? String) ?? ""
        XCTAssertTrue(
            rewrittenID.hasPrefix("com.626labs.RORORO.instance."),
            "real-Roblox copy must end up with per-instance bundle ID; got: \(rewrittenID)"
        )
        XCTAssertEqual(plist?["LSMultipleInstancesProhibited"] as? Bool, false)
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
