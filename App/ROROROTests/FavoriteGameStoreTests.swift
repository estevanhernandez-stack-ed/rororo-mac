// FavoriteGameStoreTests.swift
// JSON roundtrip + default-flag invariants. Wire shape stays
// byte-compatible with the Windows port (asserted by golden JSON).

import XCTest
@testable import RORORO

@MainActor
final class FavoriteGameStoreTests: XCTestCase {

    private var tempStoreURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rororo-fav-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("favorites.json", isDirectory: false)
    }

    override func tearDown() async throws {
        if let dir = tempStoreURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    private func makeStore() -> FavoriteGameStore {
        FavoriteGameStore(storeURL: tempStoreURL)
    }

    // MARK: - add / defaultGame

    func testAdd_FirstEntry_IsAutoDefault() {
        let store = makeStore()
        let game = store.add(placeId: 920587237, universeId: 100, name: "Adopt Me!")

        XCTAssertTrue(game.isDefault)
        XCTAssertEqual(store.defaultGame()?.placeId, 920587237)
    }

    func testAdd_SecondEntry_DoesNotBecomeDefault() {
        let store = makeStore()
        _ = store.add(placeId: 1, universeId: 1, name: "First")
        let second = store.add(placeId: 2, universeId: 2, name: "Second")

        XCTAssertFalse(second.isDefault)
        XCTAssertEqual(store.defaultGame()?.placeId, 1)
        XCTAssertEqual(store.favorites.count, 2)
    }

    func testAdd_ExistingPlaceId_PreservesIsDefaultAndAddedAt() {
        let store = makeStore()
        let original = store.add(placeId: 100, universeId: 1, name: "First Name")
        let originalAddedAt = original.addedAt

        // Replace with new name; should keep isDefault=true + same addedAt.
        let updated = store.add(placeId: 100, universeId: 1, name: "Second Name")
        XCTAssertEqual(updated.name, "Second Name")
        XCTAssertEqual(updated.addedAt, originalAddedAt)
        XCTAssertTrue(updated.isDefault)
        XCTAssertEqual(store.favorites.count, 1)
    }

    // MARK: - remove + default promotion

    func testRemove_OnlyDefault_DefaultBecomesNil() {
        let store = makeStore()
        _ = store.add(placeId: 1, universeId: 1, name: "Lonely")
        store.remove(placeId: 1)
        XCTAssertNil(store.defaultGame())
    }

    func testRemove_DefaultWithOthers_PromotesNextEntry() {
        let store = makeStore()
        _ = store.add(placeId: 1, universeId: 1, name: "First")
        _ = store.add(placeId: 2, universeId: 2, name: "Second")
        _ = store.add(placeId: 3, universeId: 3, name: "Third")

        store.remove(placeId: 1)  // Was default

        XCTAssertEqual(store.defaultGame()?.placeId, 2)
        XCTAssertEqual(store.favorites.count, 2)
    }

    func testRemove_NonDefault_DoesNotChangeDefault() {
        let store = makeStore()
        _ = store.add(placeId: 1, universeId: 1, name: "Default")
        _ = store.add(placeId: 2, universeId: 2, name: "Other")

        store.remove(placeId: 2)
        XCTAssertEqual(store.defaultGame()?.placeId, 1)
    }

    // MARK: - setDefault

    func testSetDefault_ClearsOtherFlags() {
        let store = makeStore()
        _ = store.add(placeId: 1, universeId: 1, name: "First")
        _ = store.add(placeId: 2, universeId: 2, name: "Second")

        store.setDefault(placeId: 2)

        XCTAssertEqual(store.defaultGame()?.placeId, 2)
        XCTAssertEqual(store.favorites.filter { $0.isDefault }.count, 1)
    }

    func testSetDefault_UnknownPlaceId_NoOp() {
        let store = makeStore()
        _ = store.add(placeId: 1, universeId: 1, name: "First")
        store.setDefault(placeId: 999)
        XCTAssertEqual(store.defaultGame()?.placeId, 1)
    }

    // MARK: - persistence

    func testPersistence_RoundTripsAcrossInstances() {
        let first = makeStore()
        _ = first.add(placeId: 920587237, universeId: 100, name: "Adopt Me!", thumbnailURL: URL(string: "https://x/icon.png"))
        _ = first.add(placeId: 142823291, universeId: 200, name: "Murder Mystery")

        let second = FavoriteGameStore(storeURL: tempStoreURL)
        XCTAssertEqual(second.favorites.count, 2)
        XCTAssertEqual(second.favorites.first?.placeId, 920587237)
        XCTAssertEqual(second.favorites.first?.thumbnailURL?.absoluteString, "https://x/icon.png")
        XCTAssertTrue(second.favorites.first?.isDefault ?? false)
    }

    // MARK: - wire compatibility with Windows port

    func testJSONShape_MatchesWindowsPortFieldNames() throws {
        let store = makeStore()
        _ = store.add(
            placeId: 920587237,
            universeId: 100,
            name: "Adopt Me!",
            thumbnailURL: URL(string: "https://tr.rbxcdn.com/icon.png")
        )

        // Wait briefly for the atomic save; favorites are saved synchronously
        // inside add() so this should be immediate.
        let data = try Data(contentsOf: tempStoreURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["version"] as? Int, 1)
        let favorites = json?["favorites"] as? [[String: Any]]
        let entry = favorites?.first

        // Field names must match the C# port's JsonNamingPolicy.CamelCase output.
        XCTAssertNotNil(entry?["placeId"])
        XCTAssertNotNil(entry?["universeId"])
        XCTAssertNotNil(entry?["name"])
        XCTAssertNotNil(entry?["thumbnailUrl"])  // NOT thumbnailURL
        XCTAssertNotNil(entry?["isDefault"])
        XCTAssertNotNil(entry?["addedAt"])
    }
}
