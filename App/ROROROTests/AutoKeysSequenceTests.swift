// AutoKeysSequenceTests.swift
// Domain value type — wraps either a legacy step list or the new D-3
// action stream (ADR 0007). The 3-step cap from the original ADR 0004
// was relaxed in wave 3c. The new 500-action cap applies only to the
// stream variant.

import CoreGraphics
import XCTest
@testable import RORORO

final class AutoKeysSequenceTests: XCTestCase {

    // MARK: - Construction

    func testInit_AcceptsEmpty() {
        XCTAssertNotNil(AutoKeysSequence(steps: []))
    }

    func testInit_AcceptsOneStep() {
        let seq = AutoKeysSequence(steps: [AutoKeysStep.spacebar()])
        XCTAssertNotNil(seq)
    }

    func testInit_AcceptsThreeSteps() {
        let three = (0..<3).map { _ in AutoKeysStep.spacebar() }
        XCTAssertNotNil(AutoKeysSequence(steps: three))
    }

    func testInit_AcceptsArbitraryLength() {
        // The 3-step cap was lifted in wave 3c — long sequences are
        // allowed; CycleBudget.hardCap is the real ceiling.
        let twenty = (0..<20).map { _ in AutoKeysStep.spacebar(after: 0.1) }
        let seq = AutoKeysSequence(steps: twenty)
        XCTAssertNotNil(seq)
        XCTAssertEqual(seq?.steps.count, 20)
    }

    // MARK: - totalDuration

    func testTotalDuration_EmptyIsZero() {
        let seq = AutoKeysSequence(steps: [])!
        XCTAssertEqual(seq.totalDuration, 0)
    }

    func testTotalDuration_SumsDelays() {
        let seq = AutoKeysSequence(steps: [
            AutoKeysStep(keyCode: 49, delayAfter: 1.0),
            AutoKeysStep(keyCode: 18, delayAfter: 2.5),
            AutoKeysStep(keyCode: 19, delayAfter: 3.0),
        ])!
        XCTAssertEqual(seq.totalDuration, 6.5, accuracy: 0.0001)
    }

    // MARK: - isEmpty

    func testIsEmpty_TrueWhenNoSteps() {
        let seq = AutoKeysSequence(steps: [])!
        XCTAssertTrue(seq.isEmpty)
    }

    func testIsEmpty_FalseWhenSteps() {
        let seq = AutoKeysSequence(steps: [AutoKeysStep.spacebar()])!
        XCTAssertFalse(seq.isEmpty)
    }

    // MARK: - Codable

    func testRoundTripsThroughJSON() throws {
        let original = AutoKeysSequence(steps: [
            AutoKeysStep.spacebar(after: 2),
            AutoKeysStep(keyCode: 18, delayAfter: 5),
        ])!
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AutoKeysSequence.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testDecode_AcceptsArbitraryStepCount() throws {
        // Decode no longer enforces a step cap — wave 3c relaxed the
        // original 3-step ADR rule. Cycle-budget validation in the
        // recorder gates oversized sequences from saving.
        let json = """
        { "steps": [
            { "keyCode": 49, "delayAfter": 0 },
            { "keyCode": 49, "delayAfter": 0 },
            { "keyCode": 49, "delayAfter": 0 },
            { "keyCode": 49, "delayAfter": 0 },
            { "keyCode": 49, "delayAfter": 0 }
        ] }
        """.data(using: .utf8)!
        let seq = try JSONDecoder().decode(AutoKeysSequence.self, from: json)
        XCTAssertEqual(seq.steps.count, 5)
    }

    func testDecode_AcceptsThreeSteps() throws {
        let json = """
        { "steps": [
            { "keyCode": 49, "delayAfter": 0 },
            { "keyCode": 18, "delayAfter": 1 },
            { "keyCode": 19, "delayAfter": 2 }
        ] }
        """.data(using: .utf8)!
        let seq = try JSONDecoder().decode(AutoKeysSequence.self, from: json)
        XCTAssertEqual(seq.steps.count, 3)
        XCTAssertEqual(seq.totalDuration, 3, accuracy: 0.0001)
    }

    // MARK: - D-3.1 — Variant migration (ADR 0007)

    func testInit_StepsConstructor_BuildsLegacyVariant() {
        let seq = AutoKeysSequence(steps: [AutoKeysStep.spacebar()])!
        XCTAssertTrue(seq.isLegacy)
        XCTAssertFalse(seq.isStream)
        XCTAssertEqual(seq.steps.count, 1)
        XCTAssertTrue(seq.actions.isEmpty)
    }

    func testInit_ActionsConstructor_BuildsStreamVariant() {
        let actions: [AutoKeysAction] = [
            .keyDown(keyCode: 49, modifiers: 0, dt: 0),
            .keyUp(keyCode: 49, modifiers: 0, dt: 0.020),
        ]
        let seq = AutoKeysSequence(actions: actions)!
        XCTAssertTrue(seq.isStream)
        XCTAssertFalse(seq.isLegacy)
        XCTAssertEqual(seq.actions.count, 2)
        XCTAssertTrue(seq.steps.isEmpty)
        XCTAssertFalse(seq.isShared)
    }

    func testInit_ActionsConstructor_HonoursIsShared() {
        let seq = AutoKeysSequence(
            actions: [.keyDown(keyCode: 49, modifiers: 0, dt: 0)],
            isShared: true
        )!
        XCTAssertTrue(seq.isShared)
    }

    func testInit_ActionsConstructor_AcceptsExactlyAtCap() {
        let actions = Array(
            repeating: AutoKeysAction.keyDown(keyCode: 49, modifiers: 0, dt: 0.001),
            count: AutoKeysSequence.maxActionCount
        )
        XCTAssertNotNil(AutoKeysSequence(actions: actions))
    }

    func testInit_ActionsConstructor_RefusesOverCap() {
        let actions = Array(
            repeating: AutoKeysAction.keyDown(keyCode: 49, modifiers: 0, dt: 0.001),
            count: AutoKeysSequence.maxActionCount + 1
        )
        XCTAssertNil(AutoKeysSequence(actions: actions))
    }

    func testTotalDuration_Stream_SumsDt() {
        let seq = AutoKeysSequence(actions: [
            .keyDown(keyCode: 49, modifiers: 0, dt: 0.1),
            .keyUp(keyCode: 49, modifiers: 0, dt: 0.2),
            .mouseMove(rel: CGPoint(x: 10, y: 10), dt: 0.3),
        ])!
        XCTAssertEqual(seq.totalDuration, 0.6, accuracy: 0.0001)
    }

    func testIsEmpty_StreamWithNoActions() {
        let seq = AutoKeysSequence(actions: [])!
        XCTAssertTrue(seq.isStream)
        XCTAssertTrue(seq.isEmpty)
    }

    // MARK: - D-3.1 — Codable migration

    func testDecode_LegacyOnDiskShape_RoundTripsToLegacyVariant() throws {
        // Existing on-disk ADR-0004 payload shape — no `actions`, no
        // `isShared`. Decoder must produce a `.legacy` variant.
        let json = """
        { "steps": [ { "keyCode": 49, "delayAfter": 1.0 } ] }
        """.data(using: .utf8)!
        let seq = try JSONDecoder().decode(AutoKeysSequence.self, from: json)
        XCTAssertTrue(seq.isLegacy)
        XCTAssertFalse(seq.isShared)
        XCTAssertEqual(seq.steps.count, 1)
    }

    func testEncode_LegacyVariant_PreservesByteStableShape() throws {
        // ADR 0007 Decision 4: legacy bytes never get rewritten until
        // the user re-records. Verify encode emits `{"steps":[...]}`
        // and does NOT inject `isShared` or `actions` keys.
        let seq = AutoKeysSequence(steps: [AutoKeysStep.spacebar(after: 2)])!
        let data = try JSONEncoder().encode(seq)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(dict["steps"])
        XCTAssertNil(dict["actions"])
        XCTAssertNil(dict["isShared"])
    }

    func testDecode_StreamShape_RoundTripsToStreamVariant() throws {
        let original = AutoKeysSequence(
            actions: [
                .keyDown(keyCode: 13, modifiers: 0, dt: 0),
                .mouseMove(rel: CGPoint(x: 100, y: 200), dt: 0.016),
                .mouseDown(.left, rel: CGPoint(x: 100, y: 200), dt: 0.05),
                .mouseUp(.left, rel: CGPoint(x: 100, y: 200), dt: 0.02),
                .keyUp(keyCode: 13, modifiers: 0, dt: 0.3),
            ],
            isShared: true
        )!
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AutoKeysSequence.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.isStream)
        XCTAssertTrue(decoded.isShared)
        XCTAssertEqual(decoded.actions.count, 5)
    }

    func testDecode_StreamWithoutIsShared_DefaultsToFalse() throws {
        // Defensive — an `actions` payload without an `isShared` field
        // should decode as not-shared rather than failing.
        let json = """
        { "actions": [] }
        """.data(using: .utf8)!
        let seq = try JSONDecoder().decode(AutoKeysSequence.self, from: json)
        XCTAssertTrue(seq.isStream)
        XCTAssertFalse(seq.isShared)
    }
}
