// KeychainStoreTests.swift

import XCTest
@testable import RORORO

final class KeychainStoreTests: XCTestCase {

    private let testService = "com.626labs.rororo-mac.test-keychain"

    override func setUp() {
        super.setUp()
        // Redirect to in-memory dict so the developer's real Keychain is
        // untouched. Cleared in tearDown.
        KeychainStore.inMemoryOverride = [:]
    }

    override func tearDown() {
        KeychainStore.inMemoryOverride = nil
        super.tearDown()
    }

    func testSetThenGetRoundTripsValue() throws {
        try KeychainStore.set(service: testService, account: "user-1", value: "secret-cookie")
        let retrieved = try KeychainStore.get(service: testService, account: "user-1")
        XCTAssertEqual(retrieved, "secret-cookie")
    }

    func testGetMissingReturnsNil() throws {
        let retrieved = try KeychainStore.get(service: testService, account: "never-set")
        XCTAssertNil(retrieved)
    }

    func testSetTwiceUpdatesValue() throws {
        try KeychainStore.set(service: testService, account: "user-1", value: "first")
        try KeychainStore.set(service: testService, account: "user-1", value: "second")
        let retrieved = try KeychainStore.get(service: testService, account: "user-1")
        XCTAssertEqual(retrieved, "second")
    }

    func testDeleteRemovesValue() throws {
        try KeychainStore.set(service: testService, account: "user-1", value: "secret")
        try KeychainStore.delete(service: testService, account: "user-1")
        let retrieved = try KeychainStore.get(service: testService, account: "user-1")
        XCTAssertNil(retrieved)
    }

    func testDeleteOnMissingIsNoOp() throws {
        // Should not throw. This matches the production semantic: removing
        // an account that's already gone is fine, not an error.
        XCTAssertNoThrow(try KeychainStore.delete(service: testService, account: "never-set"))
    }

    func testServiceAndAccountIsolation() throws {
        // Same account, different services: independent.
        try KeychainStore.set(service: "service-a", account: "u1", value: "a-val")
        try KeychainStore.set(service: "service-b", account: "u1", value: "b-val")
        XCTAssertEqual(try KeychainStore.get(service: "service-a", account: "u1"), "a-val")
        XCTAssertEqual(try KeychainStore.get(service: "service-b", account: "u1"), "b-val")

        // Same service, different accounts: independent.
        try KeychainStore.set(service: testService, account: "u1", value: "u1-val")
        try KeychainStore.set(service: testService, account: "u2", value: "u2-val")
        XCTAssertEqual(try KeychainStore.get(service: testService, account: "u1"), "u1-val")
        XCTAssertEqual(try KeychainStore.get(service: testService, account: "u2"), "u2-val")
    }

    func testCookieServiceConstantIsStable() {
        // AccountStore (Phase 4) reads this. Drift would silently strand
        // existing users' cookies under the old service name.
        XCTAssertEqual(KeychainStore.cookieService, "com.626labs.rororo-mac.account-cookie")
    }
}
