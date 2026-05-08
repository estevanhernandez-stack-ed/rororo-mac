// AccountStoreTests.swift
// Covers the JSON + Keychain split — public profile data persists to a
// per-test tempfile; cookies route to KeychainStore.inMemoryOverride so
// no real Keychain item ever lands.

import XCTest
@testable import RORORO

@MainActor
final class AccountStoreTests: XCTestCase {

    private var tempStoreURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rororo-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("accounts.json", isDirectory: false)
        KeychainStore.inMemoryOverride = [:]
    }

    override func tearDown() async throws {
        if let dir = tempStoreURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: dir)
        }
        KeychainStore.inMemoryOverride = nil
        try await super.tearDown()
    }

    private func makeStore() -> AccountStore {
        AccountStore(storeURL: tempStoreURL)
    }

    // MARK: - add / cookie

    func testAdd_RoundTripsAccountAndCookie() throws {
        let store = makeStore()
        let account = Account(
            userId: "12345",
            username: "tester",
            displayName: "Tester",
            avatarThumbnailURL: URL(string: "https://example/a.png")
        )

        try store.add(account: account, cookie: "secret-cookie")

        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts.first?.userId, "12345")
        XCTAssertEqual(try store.cookie(for: "12345"), "secret-cookie")
    }

    func testAdd_TwiceForSameUser_ReplacesProfileButKeepsLatestCookie() throws {
        let store = makeStore()
        let initial = Account(userId: "12345", username: "tester", displayName: "Tester")
        try store.add(account: initial, cookie: "first-cookie")

        let updated = Account(userId: "12345", username: "tester", displayName: "Tester (Updated)")
        try store.add(account: updated, cookie: "second-cookie")

        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts.first?.displayName, "Tester (Updated)")
        XCTAssertEqual(try store.cookie(for: "12345"), "second-cookie")
    }

    func testAdd_MultipleAccounts_KeepsAllDistinct() throws {
        let store = makeStore()
        try store.add(
            account: Account(userId: "1", username: "alice", displayName: "Alice"),
            cookie: "alice-cookie"
        )
        try store.add(
            account: Account(userId: "2", username: "bob", displayName: "Bob"),
            cookie: "bob-cookie"
        )

        XCTAssertEqual(store.accounts.count, 2)
        XCTAssertEqual(try store.cookie(for: "1"), "alice-cookie")
        XCTAssertEqual(try store.cookie(for: "2"), "bob-cookie")
    }

    // MARK: - remove

    func testRemove_DropsBothProfileAndCookie() throws {
        let store = makeStore()
        try store.add(
            account: Account(userId: "12345", username: "tester", displayName: "Tester"),
            cookie: "secret"
        )

        try store.remove(userId: "12345")

        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(try store.cookie(for: "12345"))
    }

    func testRemove_OnUnknownUser_NoOps() {
        let store = makeStore()
        XCTAssertNoThrow(try store.remove(userId: "doesnt-exist"))
    }

    // MARK: - touchLastLaunched

    func testTouchLastLaunched_UpdatesTimestamp() throws {
        let store = makeStore()
        try store.add(
            account: Account(userId: "12345", username: "tester", displayName: "Tester"),
            cookie: "secret"
        )

        let before = Date()
        store.touchLastLaunched(userId: "12345")
        let after = Date()

        let stamp = try XCTUnwrap(store.accounts.first?.lastLaunchedAt)
        XCTAssertGreaterThanOrEqual(stamp, before.addingTimeInterval(-1))
        XCTAssertLessThanOrEqual(stamp, after.addingTimeInterval(1))
    }

    func testTouchLastLaunched_OnUnknownUser_DoesNotCrash() {
        let store = makeStore()
        // Just shouldn't crash; no observable side-effect to assert.
        store.touchLastLaunched(userId: "nope")
        XCTAssertTrue(store.accounts.isEmpty)
    }

    // MARK: - updateProfile

    func testUpdateProfile_UpdatesDisplayNameAndAvatar() throws {
        let store = makeStore()
        try store.add(
            account: Account(userId: "12345", username: "tester", displayName: "Old"),
            cookie: "secret"
        )

        let newAvatar = URL(string: "https://example.com/avatar.png")!
        store.updateProfile(userId: "12345", displayName: "New", avatarThumbnailURL: newAvatar)

        XCTAssertEqual(store.accounts.first?.displayName, "New")
        XCTAssertEqual(store.accounts.first?.avatarThumbnailURL, newAvatar)
    }

    // MARK: - persistence

    func testPersistence_SurvivesNewStoreInstance() throws {
        let first = makeStore()
        try first.add(
            account: Account(userId: "12345", username: "tester", displayName: "Tester"),
            cookie: "secret"
        )

        // New AccountStore instance reading the same JSON path should see
        // the previously-saved account. Cookie roundtrip via in-memory
        // override remains across the same test (KeychainStore is global).
        let second = AccountStore(storeURL: tempStoreURL)

        XCTAssertEqual(second.accounts.count, 1)
        XCTAssertEqual(second.accounts.first?.userId, "12345")
        XCTAssertEqual(try second.cookie(for: "12345"), "secret")
    }

    // MARK: - setFramerateCapOverride

    func testSetFramerateCapOverride_PersistsValueAndSurvivesReload() throws {
        let first = makeStore()
        try first.add(
            account: Account(userId: "12345", username: "tester", displayName: "Tester"),
            cookie: "secret"
        )

        first.setFramerateCapOverride(userId: "12345", cap: 30)

        XCTAssertEqual(first.accounts.first?.framerateCapOverride, 30)

        // Roundtrip via JSON to confirm Codable persistence.
        let reloaded = AccountStore(storeURL: tempStoreURL)
        XCTAssertEqual(reloaded.accounts.first?.framerateCapOverride, 30)
    }

    func testSetFramerateCapOverride_NilClearsBackToGlobal() throws {
        let store = makeStore()
        try store.add(
            account: Account(
                userId: "12345",
                username: "tester",
                displayName: "Tester",
                framerateCapOverride: 60
            ),
            cookie: "secret"
        )
        XCTAssertEqual(store.accounts.first?.framerateCapOverride, 60)

        store.setFramerateCapOverride(userId: "12345", cap: nil)

        XCTAssertNil(store.accounts.first?.framerateCapOverride)
    }

    func testSetFramerateCapOverride_OnUnknownUser_DoesNotCrash() {
        let store = makeStore()
        store.setFramerateCapOverride(userId: "nope", cap: 20)
        XCTAssertTrue(store.accounts.isEmpty)
    }

    // MARK: - Account Codable backward compatibility

    func testAccount_DecodesFromLegacyJsonWithoutFramerateField() throws {
        // accounts.json files written before the Slope A3 work do not
        // carry framerateCapOverride. Optional Codable field handling
        // should treat the missing key as nil, NOT throw.
        let legacyJson = """
        [
          {
            "userId": "12345",
            "username": "tester",
            "displayName": "Tester"
          }
        ]
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([Account].self, from: legacyJson)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.userId, "12345")
        XCTAssertNil(decoded.first?.framerateCapOverride)
    }

    func testAccount_RoundTripsFramerateOverrideThroughCodable() throws {
        let original = Account(
            userId: "1",
            username: "alice",
            displayName: "Alice",
            framerateCapOverride: 144
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(Account.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.framerateCapOverride, 144)
    }
}
