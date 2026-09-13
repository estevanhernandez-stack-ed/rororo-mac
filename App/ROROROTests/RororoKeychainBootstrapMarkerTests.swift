// RororoKeychainBootstrapMarkerTests.swift
// The onboarding marker in UserDefaults outlives the keychain file it
// describes: a user who "uninstalls" by deleting ~/Library/Keychains/
// RORORO.keychain-db but not ~/Library/Preferences/com.626labs.rororo-
// mac.plist comes back with marker == currentVersion and no keychain.
// Every Launch As then falls through to login.keychain and prompts for
// the password — the exact bug the bootstrap exists to prevent.
//
// These tests only touch UserDefaults + a non-existent path, so they
// don't need the RORORO_RUN_KEYCHAIN_AUTH_TESTS opt-in that gates the
// full bootstrap suite.

import XCTest
@testable import RORORO

final class RororoKeychainBootstrapMarkerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "rororo-keychain-marker-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testNeedsOnboarding_MarkerCurrentButKeychainFileMissing_IsTrue() {
        defaults.set(RororoKeychainBootstrap.currentVersion, forKey: RororoKeychainBootstrap.versionKey)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("rororo-missing-\(UUID().uuidString).keychain-db")
        XCTAssertTrue(
            RororoKeychainBootstrap.needsOnboarding(keychainPath: missing, defaults: defaults),
            "a current marker must not mask a deleted keychain file"
        )
    }

    func testNeedsOnboarding_MarkerBehind_IsTrueRegardlessOfFile() {
        defaults.set(RororoKeychainBootstrap.currentVersion - 1, forKey: RororoKeychainBootstrap.versionKey)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("rororo-missing-\(UUID().uuidString).keychain-db")
        XCTAssertTrue(RororoKeychainBootstrap.needsOnboarding(keychainPath: missing, defaults: defaults))
    }

    func testIsInstalled_MissingFile_IsFalse() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("rororo-missing-\(UUID().uuidString).keychain-db")
        XCTAssertFalse(RororoKeychainBootstrap.isInstalled(keychainPath: missing))
    }
}
