// PrivateServerStoreTests.swift
// JSON roundtrip + identity preservation + wire compatibility.

import XCTest
@testable import RORORO

@MainActor
final class PrivateServerStoreTests: XCTestCase {

    private var tempStoreURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rororo-ps-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("private-servers.json", isDirectory: false)
    }

    override func tearDown() async throws {
        if let dir = tempStoreURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    private func makeStore() -> PrivateServerStore {
        PrivateServerStore(storeURL: tempStoreURL)
    }

    // MARK: - add / get / remove

    func testAdd_NewServer_GetsFreshUUID() {
        let store = makeStore()
        let server = store.add(placeId: 100, code: "ABC", codeKind: .linkCode, name: "Friend group")

        XCTAssertEqual(server.placeId, 100)
        XCTAssertEqual(server.code, "ABC")
        XCTAssertEqual(server.codeKind, .linkCode)
        XCTAssertNotNil(store.get(id: server.id))
    }

    func testAdd_SamePlaceAndCode_PreservesUUIDAndAddedAt() {
        let store = makeStore()
        let original = store.add(placeId: 100, code: "ABC", codeKind: .linkCode, name: "First name")
        let originalId = original.id
        let originalAddedAt = original.addedAt

        // Re-paste same share URL with new display name.
        let updated = store.add(placeId: 100, code: "ABC", codeKind: .linkCode, name: "Better name")

        XCTAssertEqual(updated.id, originalId)
        XCTAssertEqual(updated.addedAt, originalAddedAt)
        XCTAssertEqual(updated.name, "Better name")
        XCTAssertEqual(store.servers.count, 1)
    }

    func testAdd_DifferentCode_CreatesSecondEntry() {
        let store = makeStore()
        _ = store.add(placeId: 100, code: "ABC", codeKind: .linkCode, name: "Server 1")
        _ = store.add(placeId: 100, code: "XYZ", codeKind: .linkCode, name: "Server 2")
        XCTAssertEqual(store.servers.count, 2)
    }

    func testRemove_DropsRow() {
        let store = makeStore()
        let server = store.add(placeId: 100, code: "ABC", codeKind: .linkCode, name: "X")
        store.remove(id: server.id)
        XCTAssertNil(store.get(id: server.id))
    }

    // MARK: - touchLastLaunched

    func testTouchLastLaunched_SetsTimestamp() {
        let store = makeStore()
        let server = store.add(placeId: 100, code: "ABC", codeKind: .linkCode, name: "X")
        XCTAssertNil(server.lastLaunchedAt)

        let before = Date()
        store.touchLastLaunched(id: server.id)
        let after = Date()

        let fetched = store.get(id: server.id)
        let stamp = fetched?.lastLaunchedAt
        XCTAssertNotNil(stamp)
        XCTAssertGreaterThanOrEqual(stamp ?? .distantPast, before.addingTimeInterval(-1))
        XCTAssertLessThanOrEqual(stamp ?? .distantFuture, after.addingTimeInterval(1))
    }

    // MARK: - persistence

    func testPersistence_RoundTripsServers() {
        let first = makeStore()
        let s1 = first.add(placeId: 100, code: "ABC", codeKind: .linkCode, name: "Server 1")
        _ = first.add(placeId: 200, code: "XYZ", codeKind: .accessCode, name: "Server 2")

        let second = PrivateServerStore(storeURL: tempStoreURL)

        XCTAssertEqual(second.servers.count, 2)
        XCTAssertEqual(second.servers.first?.id, s1.id)
        XCTAssertEqual(second.servers.first?.code, "ABC")
        XCTAssertEqual(second.servers.first?.codeKind, .linkCode)
        XCTAssertEqual(second.servers.last?.codeKind, .accessCode)
    }

    // MARK: - wire compatibility

    func testJSONShape_MatchesWindowsPortFieldNames() throws {
        let store = makeStore()
        _ = store.add(
            placeId: 920587237,
            code: "share-link-token",
            codeKind: .linkCode,
            name: "Friend group"
        )

        let data = try Data(contentsOf: tempStoreURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["version"] as? Int, 1)
        let servers = json?["servers"] as? [[String: Any]]
        let entry = servers?.first

        XCTAssertNotNil(entry?["id"])
        XCTAssertNotNil(entry?["placeId"])
        XCTAssertNotNil(entry?["code"])
        // CodeKind should serialize as a PascalCase string ("LinkCode") to
        // match the C# enum-as-string default.
        XCTAssertEqual(entry?["codeKind"] as? String, "LinkCode")
        XCTAssertNotNil(entry?["name"])
        XCTAssertNotNil(entry?["placeName"])
        XCTAssertNotNil(entry?["addedAt"])
    }
}
