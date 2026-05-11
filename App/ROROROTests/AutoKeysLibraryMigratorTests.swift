// AutoKeysLibraryMigratorTests.swift
// Wave D-4.2 — covers the pure migration helper that translates the
// D-3 per-account model into the D-4 library model.

import XCTest
@testable import RORORO

final class AutoKeysLibraryMigratorTests: XCTestCase {

    // MARK: - Helpers

    private func legacyAccount(
        id: String,
        autoKeys: AutoKeysSequence? = nil,
        sourceId: String? = nil,
        activeMacroId: String? = nil
    ) -> Account {
        Account(
            userId: id,
            username: id,
            displayName: id,
            autoKeys: autoKeys,
            autoKeysSourceAccountId: sourceId,
            activeMacroId: activeMacroId
        )
    }

    private func streamSeq(
        keyCode: CGKeyCode = 49,
        shared: Bool = false,
        name: String? = nil
    ) -> AutoKeysSequence {
        AutoKeysSequence(
            actions: [.keyDown(keyCode: keyCode, modifiers: 0, dt: 0)],
            isShared: shared,
            name: name
        )!
    }

    // MARK: - Migration

    func testMigrate_AccountWithOwnAutoKeys_CreatesMacroAndSetsActiveId() {
        let seq = streamSeq(name: "Combat")
        let acct = legacyAccount(id: "alice", autoKeys: seq)
        let outcome = AutoKeysLibraryMigrator.migrate(
            accounts: [acct],
            existingMacros: []
        )
        XCTAssertEqual(outcome.createdMacros.count, 1)
        let macro = outcome.createdMacros[0]
        XCTAssertEqual(macro.name, "Combat")
        XCTAssertEqual(macro.ownerUserId, "alice")
        XCTAssertEqual(outcome.updatedAccounts.count, 1)
        XCTAssertEqual(outcome.updatedAccounts[0].activeMacroId, macro.id)
        XCTAssertNil(outcome.updatedAccounts[0].autoKeys)
    }

    func testMigrate_AccountWithSharingReference_PointsAtSourcesMigratedMacro() {
        let aliceSeq = streamSeq(shared: true, name: "Combat")
        let alice = legacyAccount(id: "alice", autoKeys: aliceSeq)
        let bob = legacyAccount(id: "bob", sourceId: "alice")
        let outcome = AutoKeysLibraryMigrator.migrate(
            accounts: [alice, bob],
            existingMacros: []
        )
        XCTAssertEqual(outcome.createdMacros.count, 1)
        let aliceMacro = outcome.createdMacros[0]
        XCTAssertEqual(aliceMacro.ownerUserId, "alice")
        // Alice's account points at her own macro.
        let aliceUpdated = outcome.updatedAccounts.first { $0.userId == "alice" }!
        XCTAssertEqual(aliceUpdated.activeMacroId, aliceMacro.id)
        // Bob's account points at Alice's macro (translated reference).
        let bobUpdated = outcome.updatedAccounts.first { $0.userId == "bob" }!
        XCTAssertEqual(bobUpdated.activeMacroId, aliceMacro.id)
        XCTAssertNil(bobUpdated.autoKeysSourceAccountId)
    }

    func testMigrate_AccountWithReferenceToMissingSource_LeavesActiveMacroIdNil() {
        let bob = legacyAccount(id: "bob", sourceId: "ghost")
        let outcome = AutoKeysLibraryMigrator.migrate(
            accounts: [bob],
            existingMacros: []
        )
        XCTAssertTrue(outcome.createdMacros.isEmpty)
        XCTAssertNil(outcome.updatedAccounts[0].activeMacroId)
        // Source reference is cleared regardless — broken reference
        // never stays around.
        XCTAssertNil(outcome.updatedAccounts[0].autoKeysSourceAccountId)
    }

    func testMigrate_AccountWithNothing_LeavesEverythingNil() {
        let acct = legacyAccount(id: "alice")
        let outcome = AutoKeysLibraryMigrator.migrate(
            accounts: [acct],
            existingMacros: []
        )
        XCTAssertTrue(outcome.createdMacros.isEmpty)
        XCTAssertNil(outcome.updatedAccounts[0].activeMacroId)
    }

    func testMigrate_LegacyVariant_MigratesAsLegacyMacro() {
        let legacySeq = AutoKeysSequence(steps: [.spacebar(after: 1.0)])!
        let acct = legacyAccount(id: "alice", autoKeys: legacySeq)
        let outcome = AutoKeysLibraryMigrator.migrate(
            accounts: [acct],
            existingMacros: []
        )
        XCTAssertEqual(outcome.createdMacros.count, 1)
        XCTAssertTrue(outcome.createdMacros[0].isLegacy)
    }

    // MARK: - Idempotency

    func testMigrate_AccountAlreadyMigrated_LeavesUnchanged() {
        // Setup: Alice has activeMacroId pointing at an existing macro,
        // no legacy autoKeys field.
        let existingMacro = Macro(
            id: "abc",
            name: "Combat",
            ownerUserId: "alice",
            variant: .stream([.keyDown(keyCode: 49, modifiers: 0, dt: 0)])
        )
        let alice = legacyAccount(id: "alice", activeMacroId: "abc")
        let outcome = AutoKeysLibraryMigrator.migrate(
            accounts: [alice],
            existingMacros: [existingMacro]
        )
        XCTAssertTrue(outcome.createdMacros.isEmpty)
        XCTAssertEqual(outcome.updatedAccounts[0].activeMacroId, "abc")
    }

    func testMigrate_TwoPassesIsStable() {
        // Run once, then re-run on the output. Second run should be a
        // no-op (no new macros, no account changes).
        let seq = streamSeq(name: "Combat")
        let acct = legacyAccount(id: "alice", autoKeys: seq)
        let firstPass = AutoKeysLibraryMigrator.migrate(
            accounts: [acct],
            existingMacros: []
        )
        let secondPass = AutoKeysLibraryMigrator.migrate(
            accounts: firstPass.updatedAccounts,
            existingMacros: firstPass.createdMacros
        )
        XCTAssertTrue(secondPass.createdMacros.isEmpty)
        XCTAssertEqual(secondPass.updatedAccounts, firstPass.updatedAccounts)
    }
}
