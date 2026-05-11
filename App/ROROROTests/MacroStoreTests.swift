// MacroStoreTests.swift
// Wave D-4.1 — library store. Covers CRUD + sharedMacros filter +
// JSON round-trip + survival across reload.

import XCTest
@testable import RORORO

@MainActor
final class MacroStoreTests: XCTestCase {

    private var tempStoreURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rororo-macros-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("macros.json", isDirectory: false)
    }

    override func tearDown() async throws {
        if let dir = tempStoreURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    private func makeStore() -> MacroStore {
        MacroStore(storeURL: tempStoreURL)
    }

    private func makeMacro(
        id: String = UUID().uuidString,
        name: String = "Test",
        ownerUserId: String? = nil,
        isShared: Bool = true,
        variant: AutoKeysSequence.Variant = .stream([.keyDown(keyCode: 49, modifiers: 0, dt: 0)])
    ) -> Macro {
        Macro(id: id, name: name, ownerUserId: ownerUserId, variant: variant, isShared: isShared)
    }

    // MARK: - CRUD

    func testUpsert_AddsNewMacro() {
        let store = makeStore()
        let m = makeMacro(name: "Combat")
        store.upsert(m)
        XCTAssertEqual(store.macros.count, 1)
        XCTAssertEqual(store.macros.first?.name, "Combat")
    }

    func testUpsert_ReplacesExistingMacroWithSameId() {
        let store = makeStore()
        store.upsert(makeMacro(id: "abc", name: "Combat"))
        store.upsert(makeMacro(id: "abc", name: "Combat v2"))
        XCTAssertEqual(store.macros.count, 1)
        XCTAssertEqual(store.macros.first?.name, "Combat v2")
    }

    func testRename_UpdatesNameAndPreservesEverythingElse() {
        let store = makeStore()
        let m = makeMacro(id: "abc", name: "Old", ownerUserId: "1", isShared: true)
        store.upsert(m)
        store.rename(id: "abc", to: "New name")
        let updated = store.macro(id: "abc")
        XCTAssertEqual(updated?.name, "New name")
        XCTAssertEqual(updated?.ownerUserId, "1")
        XCTAssertEqual(updated?.isShared, true)
    }

    func testRename_TrimsWhitespace() {
        let store = makeStore()
        store.upsert(makeMacro(id: "abc"))
        store.rename(id: "abc", to: "  Padded  ")
        XCTAssertEqual(store.macro(id: "abc")?.name, "Padded")
    }

    func testRename_EmptyOrWhitespaceOnly_Ignored() {
        let store = makeStore()
        store.upsert(makeMacro(id: "abc", name: "Original"))
        store.rename(id: "abc", to: "  ")
        XCTAssertEqual(store.macro(id: "abc")?.name, "Original")
    }

    func testRename_UnknownId_NoOp() {
        let store = makeStore()
        store.rename(id: "nope", to: "Whatever")
        XCTAssertTrue(store.macros.isEmpty)
    }

    func testSetShared_FlipsFlag() {
        let store = makeStore()
        store.upsert(makeMacro(id: "abc", isShared: true))
        store.setShared(id: "abc", isShared: false)
        XCTAssertEqual(store.macro(id: "abc")?.isShared, false)
        store.setShared(id: "abc", isShared: true)
        XCTAssertEqual(store.macro(id: "abc")?.isShared, true)
    }

    func testDelete_RemovesMacro() {
        let store = makeStore()
        store.upsert(makeMacro(id: "abc"))
        XCTAssertEqual(store.macros.count, 1)
        store.delete(id: "abc")
        XCTAssertTrue(store.macros.isEmpty)
    }

    // MARK: - sharedMacros filter

    func testSharedMacros_OnlyReturnsSharedMacros() {
        let store = makeStore()
        store.upsert(makeMacro(id: "a", isShared: true))
        store.upsert(makeMacro(id: "b", isShared: false))
        let shared = store.sharedMacros()
        XCTAssertEqual(shared.count, 1)
        XCTAssertEqual(shared.first?.id, "a")
    }

    func testSharedMacros_ExcludesByOwnerWhenProvided() {
        let store = makeStore()
        store.upsert(makeMacro(id: "a", ownerUserId: "alice", isShared: true))
        store.upsert(makeMacro(id: "b", ownerUserId: "bob", isShared: true))
        let forCarol = store.sharedMacros(excludingOwner: "alice")
        XCTAssertEqual(forCarol.count, 1)
        XCTAssertEqual(forCarol.first?.id, "b")
    }

    func testMacrosOwnedBy_FiltersByOwner() {
        let store = makeStore()
        store.upsert(makeMacro(id: "a", ownerUserId: "alice"))
        store.upsert(makeMacro(id: "b", ownerUserId: "bob"))
        store.upsert(makeMacro(id: "c", ownerUserId: "alice"))
        XCTAssertEqual(store.macros(ownedBy: "alice").map(\.id).sorted(), ["a", "c"])
    }

    // MARK: - Persistence

    func testPersistence_SurvivesReload() {
        let first = makeStore()
        first.upsert(makeMacro(id: "abc", name: "Combat", ownerUserId: "1"))
        first.upsert(makeMacro(id: "def", name: "Farming", ownerUserId: "2"))

        let reloaded = MacroStore(storeURL: tempStoreURL)
        XCTAssertEqual(reloaded.macros.count, 2)
        XCTAssertEqual(reloaded.macro(id: "abc")?.name, "Combat")
        XCTAssertEqual(reloaded.macro(id: "def")?.name, "Farming")
    }
}
