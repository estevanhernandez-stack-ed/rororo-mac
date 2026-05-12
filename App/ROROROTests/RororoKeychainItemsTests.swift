// RororoKeychainItemsTests.swift
// Targets a temp-path keychain so the dev's login keychain stays clean.

import XCTest
@testable import RORORO

final class RororoKeychainItemsTests: XCTestCase {

    private var tempPath: URL!

    override func setUp() {
        super.setUp()
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
