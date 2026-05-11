// AutoKeysSharingResolverTests.swift
// Wave D-4.3 — covers the library-aware resolver. The D-3.5 / D-3.8
// pre-library resolver tests are retired (the cases they exercised
// — ownEmpty / ownRecording / sharedFrom / orphaned / sourceNotShared
// — no longer exist; they were per-account fields the migrator
// already promoted to library macros).

import XCTest
@testable import RORORO

final class AutoKeysSharingResolverTests: XCTestCase {

    // MARK: - Helpers

    private func account(
        id: String,
        activeMacroId: String? = nil
    ) -> Account {
        Account(
            userId: id,
            username: id,
            displayName: id,
            activeMacroId: activeMacroId
        )
    }

    private func streamMacro(
        id: String,
        ownerUserId: String? = nil,
        isShared: Bool = true,
        name: String = "Test"
    ) -> Macro {
        Macro(
            id: id,
            name: name,
            ownerUserId: ownerUserId,
            variant: .stream([.keyDown(keyCode: 49, modifiers: 0, dt: 0)]),
            isShared: isShared
        )
    }

    // MARK: - activeMacroId path

    func testResolve_ActiveMacroFound_ReturnsPlaying() {
        let macro = streamMacro(id: "abc")
        let a = account(id: "alice", activeMacroId: "abc")
        XCTAssertEqual(
            AutoKeysSharingResolver.resolve(account: a, macros: [macro]),
            .playing(macro)
        )
    }

    func testResolve_ActiveMacroMissing_ReturnsOrphaned() {
        let a = account(id: "alice", activeMacroId: "ghost")
        XCTAssertEqual(
            AutoKeysSharingResolver.resolve(account: a, macros: []),
            .orphaned(macroId: "ghost")
        )
    }

    func testResolve_NoActiveMacro_NoDefault_ReturnsNone() {
        let a = account(id: "alice")
        XCTAssertEqual(
            AutoKeysSharingResolver.resolve(account: a, macros: []),
            .none
        )
    }

    // MARK: - Global default fallback

    func testResolve_StayAliveDefault_SynthesizesSequence() {
        let a = account(id: "alice")
        let resolution = AutoKeysSharingResolver.resolve(
            account: a,
            macros: [],
            globalDefault: .stayAlive
        )
        guard case let .usingGlobalDefault(reason, seq) = resolution else {
            XCTFail("Expected usingGlobalDefault, got \(resolution)")
            return
        }
        XCTAssertEqual(reason, .stayAlive)
        XCTAssertTrue(seq.isLegacy)
        XCTAssertEqual(seq.steps.first?.keyCode, 49)
    }

    func testResolve_StayAliveDefault_DoesNotOverrideActiveMacro() {
        let macro = streamMacro(id: "abc")
        let a = account(id: "alice", activeMacroId: "abc")
        XCTAssertEqual(
            AutoKeysSharingResolver.resolve(
                account: a,
                macros: [macro],
                globalDefault: .stayAlive
            ),
            .playing(macro)
        )
    }

    // MARK: - .useMacro path (D-4.3)

    func testResolve_UseMacroDefault_ResolvesToTargetMacro() {
        let macro = streamMacro(id: "lib1", name: "Combat")
        let a = account(id: "alice")
        let resolution = AutoKeysSharingResolver.resolve(
            account: a,
            macros: [macro],
            globalDefault: .useMacro(macroId: "lib1")
        )
        XCTAssertEqual(
            resolution,
            .usingGlobalDefault(reason: .usingMacro(macro), sequence: macro.sequence)
        )
    }

    func testResolve_UseMacroDefault_MissingMacro_FallsThroughToNone() {
        let a = account(id: "alice")
        XCTAssertEqual(
            AutoKeysSharingResolver.resolve(
                account: a,
                macros: [],
                globalDefault: .useMacro(macroId: "ghost")
            ),
            .none
        )
    }

    // MARK: - .useShared legacy path (D-3.8 compatibility)

    func testResolve_UseSharedDefault_FindsMacroOwnedBySpecifiedUser() {
        let macro = streamMacro(id: "lib1", ownerUserId: "bob", isShared: true)
        let a = account(id: "alice")
        let resolution = AutoKeysSharingResolver.resolve(
            account: a,
            macros: [macro],
            globalDefault: .useShared(sourceUserId: "bob")
        )
        XCTAssertEqual(
            resolution,
            .usingGlobalDefault(reason: .usingMacro(macro), sequence: macro.sequence)
        )
    }

    func testResolve_UseSharedDefault_NonSharedOwnerMacro_FallsThroughToNone() {
        let unshared = streamMacro(id: "lib1", ownerUserId: "bob", isShared: false)
        let a = account(id: "alice")
        XCTAssertEqual(
            AutoKeysSharingResolver.resolve(
                account: a,
                macros: [unshared],
                globalDefault: .useShared(sourceUserId: "bob")
            ),
            .none
        )
    }

    func testResolve_UseSharedDefault_SelfReferenceFallsThroughToNone() {
        let macro = streamMacro(id: "lib1", ownerUserId: "alice", isShared: true)
        let a = account(id: "alice")
        XCTAssertEqual(
            AutoKeysSharingResolver.resolve(
                account: a,
                macros: [macro],
                globalDefault: .useShared(sourceUserId: "alice")
            ),
            .none
        )
    }

    // MARK: - playableSequence convenience

    func testPlayableSequence_Playing_ReturnsMacroSequence() {
        let macro = streamMacro(id: "abc")
        let a = account(id: "alice", activeMacroId: "abc")
        XCTAssertEqual(
            AutoKeysSharingResolver.playableSequence(account: a, macros: [macro]),
            macro.sequence
        )
    }

    func testPlayableSequence_None_ReturnsNil() {
        let a = account(id: "alice")
        XCTAssertNil(
            AutoKeysSharingResolver.playableSequence(account: a, macros: [])
        )
    }

    func testPlayableSequence_Orphaned_ReturnsNil() {
        let a = account(id: "alice", activeMacroId: "ghost")
        XCTAssertNil(
            AutoKeysSharingResolver.playableSequence(account: a, macros: [])
        )
    }

    func testPlayableSequence_StayAliveDefault_ReturnsNonNil() {
        let a = account(id: "alice")
        XCTAssertNotNil(
            AutoKeysSharingResolver.playableSequence(
                account: a,
                macros: [],
                globalDefault: .stayAlive
            )
        )
    }

    func testPlayableSequence_EmptyMacro_ReturnsNil() {
        // Defensive: a macro with no actions in the library returns nil
        // from playableSequence — cycler skips rather than firing 0
        // events forever.
        let empty = Macro(
            id: "empty",
            name: "Empty",
            variant: .stream([])
        )
        let a = account(id: "alice", activeMacroId: "empty")
        XCTAssertNil(
            AutoKeysSharingResolver.playableSequence(account: a, macros: [empty])
        )
    }
}
