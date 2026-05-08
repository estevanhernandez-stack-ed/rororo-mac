// AutoKeysSequenceTests.swift
// Domain value type — ordered list of up to 3 steps with cap enforcement
// at construction AND decode time.

import XCTest
@testable import RORORO

final class AutoKeysSequenceTests: XCTestCase {

    // MARK: - Construction cap

    func testInit_AcceptsEmpty() {
        XCTAssertNotNil(AutoKeysSequence(steps: []))
    }

    func testInit_AcceptsOneStep() {
        let seq = AutoKeysSequence(steps: [AutoKeysStep.spacebar()])
        XCTAssertNotNil(seq)
    }

    func testInit_AcceptsExactlyMaxSteps() {
        let three = (0..<3).map { _ in AutoKeysStep.spacebar() }
        XCTAssertNotNil(AutoKeysSequence(steps: three))
    }

    func testInit_ReturnsNilAboveMaxSteps() {
        let four = (0..<4).map { _ in AutoKeysStep.spacebar() }
        XCTAssertNil(AutoKeysSequence(steps: four))
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

    func testDecode_RejectsExcessSteps() {
        let json = """
        { "steps": [
            { "keyCode": 49, "delayAfter": 0 },
            { "keyCode": 49, "delayAfter": 0 },
            { "keyCode": 49, "delayAfter": 0 },
            { "keyCode": 49, "delayAfter": 0 }
        ] }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(AutoKeysSequence.self, from: json))
    }

    func testDecode_AcceptsExactlyMaxSteps() throws {
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
}
