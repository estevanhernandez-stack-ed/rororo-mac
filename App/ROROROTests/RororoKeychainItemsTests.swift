// RororoKeychainItemsTests.swift
// Targets a temp-path keychain so the dev's login keychain stays clean.

import XCTest
@testable import RORORO

final class RororoKeychainItemsTests: XCTestCase {

    private var tempPath: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Every test calls RororoKeychainItems.add, which shells out to
        // `security add-generic-password -A`. The `-A` flag (allow-any-app
        // ACL) is security-sensitive and macOS prompts the user the first
        // time it's set on a fresh keychain. Headless CI has no UI to
        // accept the prompt → tests hang. Opt-in locally via
        // RORORO_RUN_KEYCHAIN_AUTH_TESTS=1 so the developer accepts the
        // prompts knowingly.
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RORORO_RUN_KEYCHAIN_AUTH_TESTS"] != nil,
            "Opt-in only — set RORORO_RUN_KEYCHAIN_AUTH_TESTS=1 locally to exercise"
        )
        tempPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rororo-keychain-items-test-\(UUID().uuidString).keychain")
        try? RororoKeychain.create(keychainPath: tempPath, password: "")
        try? RororoKeychain.unlock(keychainPath: tempPath, password: "")
    }

    override func tearDown() {
        try? RororoKeychain.removeFromSearchListIfPresent(keychainPath: tempPath)
        try? RororoKeychain.delete(keychainPath: tempPath)
        super.tearDown()
    }

    func testAddGenericPasswordCreatesItem() throws {
        let item = RoroKeychainItem(
            kind: .genericPassword,
            account: "https://www.roblox.com/:SharedROBLOSECURITYForStudio",
            service: "https://www.roblox.com/:SharedROBLOSECURITYForStudio"
        )
        try RororoKeychainItems.add(item, toKeychainAt: tempPath)

        XCTAssertTrue(
            try RororoKeychainItems.exists(item, inKeychainAt: tempPath),
            "freshly added generic-password item should be queryable from the keychain"
        )
    }

    func testAddInternetPasswordCreatesItem() throws {
        let item = RoroKeychainItem(
            kind: .internetPassword,
            server: "www.roblox.com",
            path: "/:Probe",
            account: "https://www.roblox.com/:Probe",
            protocolType: .https
        )
        try RororoKeychainItems.add(item, toKeychainAt: tempPath)

        XCTAssertTrue(
            try RororoKeychainItems.exists(item, inKeychainAt: tempPath),
            "freshly added internet-password item should be queryable from the keychain"
        )
    }

    func testAddIsIdempotent() throws {
        let item = RoroKeychainItem(
            kind: .genericPassword,
            account: "https://www.roblox.com/:SharedROBLOSECURITYForStudio",
            service: "https://www.roblox.com/:SharedROBLOSECURITYForStudio"
        )
        try RororoKeychainItems.add(item, toKeychainAt: tempPath)
        XCTAssertNoThrow(
            try RororoKeychainItems.add(item, toKeychainAt: tempPath),
            "re-adding an existing item should be a no-op, not an error"
        )
    }
}
