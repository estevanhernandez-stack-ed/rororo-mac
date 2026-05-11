// AutoKeysSharingResolverTests.swift
// Wave D-3.2 — pure helper, no fakes. Covers all 5 Resolution cases
// plus the playableSequence convenience.

import XCTest
@testable import RORORO

final class AutoKeysSharingResolverTests: XCTestCase {

    // MARK: - Helpers

    private func legacy() -> AutoKeysSequence {
        AutoKeysSequence(steps: [AutoKeysStep.spacebar(after: 1)])!
    }

    private func stream(shared: Bool = false) -> AutoKeysSequence {
        AutoKeysSequence(
            actions: [.keyDown(keyCode: 49, modifiers: 0, dt: 0)],
            isShared: shared
        )!
    }

    private func account(
        id: String,
        autoKeys: AutoKeysSequence? = nil,
        ref: String? = nil
    ) -> Account {
        Account(
            userId: id,
            username: id,
            displayName: id,
            autoKeys: autoKeys,
            autoKeysSourceAccountId: ref
        )
    }

    // MARK: - Cases

    func testResolve_NoReference_NoOwn_YieldsOwnEmpty() {
        let a = account(id: "1")
        XCTAssertEqual(AutoKeysSharingResolver.resolve(account: a, all: [a]), .ownEmpty)
    }

    func testResolve_NoReference_HasOwnLegacy_YieldsOwnRecording() {
        let seq = legacy()
        let a = account(id: "1", autoKeys: seq)
        XCTAssertEqual(
            AutoKeysSharingResolver.resolve(account: a, all: [a]),
            .ownRecording(seq)
        )
    }

    func testResolve_NoReference_HasOwnStream_YieldsOwnRecording() {
        let seq = stream()
        let a = account(id: "1", autoKeys: seq)
        XCTAssertEqual(
            AutoKeysSharingResolver.resolve(account: a, all: [a]),
            .ownRecording(seq)
        )
    }

    func testResolve_ReferenceToSharedSource_YieldsSharedFrom() {
        let sharedSeq = stream(shared: true)
        let source = account(id: "1", autoKeys: sharedSeq)
        let consumer = account(id: "2", ref: "1")
        XCTAssertEqual(
            AutoKeysSharingResolver.resolve(account: consumer, all: [source, consumer]),
            .sharedFrom(sourceAccountId: "1", sequence: sharedSeq)
        )
    }

    func testResolve_ReferenceToMissingSource_YieldsOrphaned() {
        let consumer = account(id: "2", ref: "1")
        XCTAssertEqual(
            AutoKeysSharingResolver.resolve(account: consumer, all: [consumer]),
            .orphaned(missingSourceAccountId: "1")
        )
    }

    func testResolve_ReferenceToSourceWithNilAutoKeys_YieldsOrphaned() {
        let source = account(id: "1", autoKeys: nil)
        let consumer = account(id: "2", ref: "1")
        XCTAssertEqual(
            AutoKeysSharingResolver.resolve(account: consumer, all: [source, consumer]),
            .orphaned(missingSourceAccountId: "1")
        )
    }

    func testResolve_ReferenceToSourceWithEmptyAutoKeys_YieldsOrphaned() {
        // An empty stream-variant recording on the source is treated the
        // same as nil — nothing to play.
        let source = account(id: "1", autoKeys: AutoKeysSequence(actions: [])!)
        let consumer = account(id: "2", ref: "1")
        XCTAssertEqual(
            AutoKeysSharingResolver.resolve(account: consumer, all: [source, consumer]),
            .orphaned(missingSourceAccountId: "1")
        )
    }

    func testResolve_ReferenceToNonSharedSource_YieldsSourceNotShared() {
        let notShared = stream(shared: false)
        let source = account(id: "1", autoKeys: notShared)
        let consumer = account(id: "2", ref: "1")
        XCTAssertEqual(
            AutoKeysSharingResolver.resolve(account: consumer, all: [source, consumer]),
            .sourceNotShared(sourceAccountId: "1")
        )
    }

    // MARK: - playableSequence convenience

    func testPlayableSequence_OwnRecording_ReturnsOwn() {
        let seq = legacy()
        let a = account(id: "1", autoKeys: seq)
        XCTAssertEqual(
            AutoKeysSharingResolver.playableSequence(account: a, all: [a]),
            seq
        )
    }

    func testPlayableSequence_SharedSource_ReturnsSource() {
        let sharedSeq = stream(shared: true)
        let source = account(id: "1", autoKeys: sharedSeq)
        let consumer = account(id: "2", ref: "1")
        XCTAssertEqual(
            AutoKeysSharingResolver.playableSequence(account: consumer, all: [source, consumer]),
            sharedSeq
        )
    }

    func testPlayableSequence_OrphanedReference_ReturnsNil() {
        let consumer = account(id: "2", ref: "1")
        XCTAssertNil(
            AutoKeysSharingResolver.playableSequence(account: consumer, all: [consumer])
        )
    }

    func testPlayableSequence_NonSharedSource_ReturnsNil() {
        let source = account(id: "1", autoKeys: stream(shared: false))
        let consumer = account(id: "2", ref: "1")
        XCTAssertNil(
            AutoKeysSharingResolver.playableSequence(account: consumer, all: [source, consumer])
        )
    }

    // MARK: - D-3.8 — global default fallback

    func testResolve_SkipDefault_LeavesOwnEmptyAccountSkipped() {
        let a = account(id: "1")
        XCTAssertEqual(
            AutoKeysSharingResolver.resolve(account: a, all: [a], globalDefault: .skip),
            .ownEmpty
        )
    }

    func testResolve_StayAliveDefault_SynthesizesSequenceForOwnEmpty() {
        let a = account(id: "1")
        let resolution = AutoKeysSharingResolver.resolve(
            account: a,
            all: [a],
            globalDefault: .stayAlive
        )
        guard case let .usingGlobalDefault(reason, seq) = resolution else {
            XCTFail("Expected usingGlobalDefault, got \(resolution)")
            return
        }
        XCTAssertEqual(reason, .stayAlive)
        // The synthesized sequence is a legacy 1-step spacebar — keyCode
        // 49, delayAfter 1.0.
        XCTAssertTrue(seq.isLegacy)
        XCTAssertEqual(seq.steps.count, 1)
        XCTAssertEqual(seq.steps.first?.keyCode, 49)
    }

    func testResolve_StayAliveDefault_DoesNotOverrideOwnRecording() {
        let own = legacy()
        let a = account(id: "1", autoKeys: own)
        XCTAssertEqual(
            AutoKeysSharingResolver.resolve(account: a, all: [a], globalDefault: .stayAlive),
            .ownRecording(own)
        )
    }

    func testResolve_StayAliveDefault_DoesNotOverrideExplicitReference() {
        let sharedSeq = stream(shared: true)
        let source = account(id: "1", autoKeys: sharedSeq)
        let consumer = account(id: "2", ref: "1")
        XCTAssertEqual(
            AutoKeysSharingResolver.resolve(
                account: consumer,
                all: [source, consumer],
                globalDefault: .stayAlive
            ),
            .sharedFrom(sourceAccountId: "1", sequence: sharedSeq)
        )
    }

    func testResolve_UseSharedDefault_ResolvesToSourceWhenHealthy() {
        let sharedSeq = stream(shared: true)
        let source = account(id: "1", autoKeys: sharedSeq)
        let consumer = account(id: "2")
        let resolution = AutoKeysSharingResolver.resolve(
            account: consumer,
            all: [source, consumer],
            globalDefault: .useShared(sourceUserId: "1")
        )
        XCTAssertEqual(
            resolution,
            .usingGlobalDefault(reason: .sharedFrom(sourceAccountId: "1"), sequence: sharedSeq)
        )
    }

    func testResolve_UseSharedDefault_FallsThroughToSkipWhenSourceMissing() {
        let consumer = account(id: "2")
        XCTAssertEqual(
            AutoKeysSharingResolver.resolve(
                account: consumer,
                all: [consumer],
                globalDefault: .useShared(sourceUserId: "missing")
            ),
            .ownEmpty
        )
    }

    func testResolve_UseSharedDefault_FallsThroughToSkipWhenSourceNotShared() {
        let unshared = stream(shared: false)
        let source = account(id: "1", autoKeys: unshared)
        let consumer = account(id: "2")
        XCTAssertEqual(
            AutoKeysSharingResolver.resolve(
                account: consumer,
                all: [source, consumer],
                globalDefault: .useShared(sourceUserId: "1")
            ),
            .ownEmpty
        )
    }

    func testResolve_UseSharedDefault_SelfReferenceFallsThroughToSkip() {
        // Defensive — the picker shouldn't allow the user to point the
        // global default at themselves, but if it did, the resolver
        // must not loop.
        let a = account(id: "1")
        XCTAssertEqual(
            AutoKeysSharingResolver.resolve(
                account: a,
                all: [a],
                globalDefault: .useShared(sourceUserId: "1")
            ),
            .ownEmpty
        )
    }

    func testPlayableSequence_GlobalDefault_StayAliveReturnsNonNil() {
        let a = account(id: "1")
        XCTAssertNotNil(
            AutoKeysSharingResolver.playableSequence(
                account: a,
                all: [a],
                globalDefault: .stayAlive
            )
        )
    }

    func testPlayableSequence_GlobalDefault_SkipReturnsNil() {
        let a = account(id: "1")
        XCTAssertNil(
            AutoKeysSharingResolver.playableSequence(
                account: a,
                all: [a],
                globalDefault: .skip
            )
        )
    }
}
