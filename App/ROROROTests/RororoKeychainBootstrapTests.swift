// RororoKeychainBootstrapTests.swift
// Exercises ensureIfNeeded end-to-end against a temp keychain + an
// isolated UserDefaults suite (so test runs don't pollute the dev's
// real prefs).

import XCTest
@testable import RORORO

final class RororoKeychainBootstrapTests: XCTestCase {

    private var tempPath: URL!
    private var defaults: UserDefaults!
    private let suiteName = "rororo-keychain-bootstrap-tests"

    override func setUpWithError() throws {
        try super.setUpWithError()
        // All tests in this class exercise ensureIfNeeded, which calls
        // prependToSearchList → requires AuthorizationServices UI auth.
        // Headless runners (CI) have no UI to display the prompt; the
        // tests hang. Skipping by default — opt-in locally by setting
        // the RORORO_RUN_KEYCHAIN_AUTH_TESTS env var (Scheme → Run →
        // Arguments → Environment Variables) so the developer accepts
        // the prompt avalanche knowingly.
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RORORO_RUN_KEYCHAIN_AUTH_TESTS"] != nil,
            "Opt-in only — set RORORO_RUN_KEYCHAIN_AUTH_TESTS=1 locally to exercise"
        )
        tempPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rororo-bootstrap-test-\(UUID().uuidString).keychain")
        // Fresh defaults suite per test so the marker doesn't leak across.
        defaults = UserDefaults(suiteName: "\(suiteName)-\(UUID().uuidString)")
        defaults.removeObject(forKey: RororoKeychainBootstrap.versionKey)
    }

    override func tearDown() {
        try? RororoKeychain.removeFromSearchListIfPresent(keychainPath: tempPath)
        try? RororoKeychain.delete(keychainPath: tempPath)
        defaults.removeObject(forKey: RororoKeychainBootstrap.versionKey)
        super.tearDown()
    }

    func testEnsureCreatesKeychainAndPopulates() async throws {
        let item = RoroKeychainItem(
            kind: .genericPassword,
            account: "https://www.roblox.com/:SharedROBLOSECURITYForStudio",
            service: "https://www.roblox.com/:SharedROBLOSECURITYForStudio"
        )
        try await RororoKeychainBootstrap.ensureIfNeeded(
            keychainPath: tempPath,
            probeItems: [item],
            defaults: defaults
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: tempPath.path),
            "keychain file should exist after bootstrap"
        )
        let list = try RororoKeychain.currentSearchList()
        XCTAssertTrue(
            list.contains(RororoKeychain.canonicalPath(for: tempPath)),
            "keychain should be in user's search list"
        )
        XCTAssertEqual(
            defaults.integer(forKey: RororoKeychainBootstrap.versionKey),
            RororoKeychainBootstrap.currentVersion,
            "version marker should be set to currentVersion"
        )
        XCTAssertTrue(
            try RororoKeychainItems.exists(item, inKeychainAt: tempPath),
            "probe item should be queryable after bootstrap"
        )
    }

    func testSecondEnsureIsNoOp() async throws {
        try await RororoKeychainBootstrap.ensureIfNeeded(
            keychainPath: tempPath,
            probeItems: [],
            defaults: defaults
        )
        let priorList = try RororoKeychain.currentSearchList()

        try await RororoKeychainBootstrap.ensureIfNeeded(
            keychainPath: tempPath,
            probeItems: [],
            defaults: defaults
        )
        let secondList = try RororoKeychain.currentSearchList()

        XCTAssertEqual(
            priorList, secondList,
            "second ensureIfNeeded should not mutate the search list"
        )
    }

    func testVersionResetTriggersRePopulate() async throws {
        // Initial run: no items, version marker set.
        try await RororoKeychainBootstrap.ensureIfNeeded(
            keychainPath: tempPath,
            probeItems: [],
            defaults: defaults
        )

        // Simulate a probe-list addition + version bump: reset the marker
        // to 0 (less than currentVersion). The next ensureIfNeeded should
        // pick up the new item.
        let newItem = RoroKeychainItem(
            kind: .genericPassword,
            account: "https://www.roblox.com/:NewItemAddedInV2",
            service: "https://www.roblox.com/:NewItemAddedInV2"
        )
        defaults.set(0, forKey: RororoKeychainBootstrap.versionKey)

        try await RororoKeychainBootstrap.ensureIfNeeded(
            keychainPath: tempPath,
            probeItems: [newItem],
            defaults: defaults
        )

        XCTAssertTrue(
            try RororoKeychainItems.exists(newItem, inKeychainAt: tempPath),
            "version-marker reset should trigger a re-populate that adds the new item"
        )
    }

    func testNeedsOnboardingReflectsMarker() async throws {
        XCTAssertTrue(
            RororoKeychainBootstrap.needsOnboarding(defaults: defaults),
            "needsOnboarding should be true before ensureIfNeeded runs"
        )
        try await RororoKeychainBootstrap.ensureIfNeeded(
            keychainPath: tempPath,
            probeItems: [],
            defaults: defaults
        )
        XCTAssertFalse(
            RororoKeychainBootstrap.needsOnboarding(defaults: defaults),
            "needsOnboarding should be false after ensureIfNeeded marks the version"
        )
    }
}
