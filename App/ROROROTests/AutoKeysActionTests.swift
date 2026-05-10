// AutoKeysActionTests.swift
// Wave D-3.1 — the 5-case action enum is the new substrate for
// full-fidelity record-and-replay (ADR 0007 Decision 1). These tests
// pin the on-disk shape so a future Swift Codable synthesis change
// can't silently invalidate existing recordings.

import CoreGraphics
import XCTest
@testable import RORORO

final class AutoKeysActionTests: XCTestCase {

    // MARK: - Round-trip (all 5 cases)

    func testRoundTrip_KeyDown() throws {
        let original = AutoKeysAction.keyDown(keyCode: 49, modifiers: 0x40000, dt: 0.123)
        try assertRoundTrip(original)
    }

    func testRoundTrip_KeyUp() throws {
        let original = AutoKeysAction.keyUp(keyCode: 13, modifiers: 0, dt: 0.020)
        try assertRoundTrip(original)
    }

    func testRoundTrip_MouseMove() throws {
        let original = AutoKeysAction.mouseMove(rel: CGPoint(x: 120.5, y: 300.25), dt: 0.016)
        try assertRoundTrip(original)
    }

    func testRoundTrip_MouseDown_Left() throws {
        let original = AutoKeysAction.mouseDown(.left, rel: CGPoint(x: 50, y: 100), dt: 0.5)
        try assertRoundTrip(original)
    }

    func testRoundTrip_MouseDown_Right() throws {
        let original = AutoKeysAction.mouseDown(.right, rel: CGPoint(x: 5, y: 5), dt: 0)
        try assertRoundTrip(original)
    }

    func testRoundTrip_MouseUp_Left() throws {
        let original = AutoKeysAction.mouseUp(.left, rel: CGPoint(x: 50, y: 100), dt: 0.05)
        try assertRoundTrip(original)
    }

    func testRoundTrip_MouseUp_Right() throws {
        let original = AutoKeysAction.mouseUp(.right, rel: CGPoint(x: 5, y: 5), dt: 0)
        try assertRoundTrip(original)
    }

    // MARK: - Array round-trip (the realistic on-disk shape)

    func testRoundTrip_ActionStream() throws {
        let stream: [AutoKeysAction] = [
            .keyDown(keyCode: 13, modifiers: 0, dt: 0),
            .mouseMove(rel: CGPoint(x: 100, y: 50), dt: 0.016),
            .mouseDown(.left, rel: CGPoint(x: 100, y: 50), dt: 0.080),
            .mouseUp(.left, rel: CGPoint(x: 100, y: 50), dt: 0.020),
            .keyUp(keyCode: 13, modifiers: 0, dt: 0.300),
        ]
        let data = try JSONEncoder().encode(stream)
        let decoded = try JSONDecoder().decode([AutoKeysAction].self, from: data)
        XCTAssertEqual(decoded, stream)
    }

    // MARK: - dt accessor

    func testDt_AccessibleAcrossCases() {
        XCTAssertEqual(AutoKeysAction.keyDown(keyCode: 49, modifiers: 0, dt: 0.1).dt, 0.1)
        XCTAssertEqual(AutoKeysAction.keyUp(keyCode: 49, modifiers: 0, dt: 0.2).dt, 0.2)
        XCTAssertEqual(AutoKeysAction.mouseMove(rel: .zero, dt: 0.3).dt, 0.3)
        XCTAssertEqual(AutoKeysAction.mouseDown(.left, rel: .zero, dt: 0.4).dt, 0.4)
        XCTAssertEqual(AutoKeysAction.mouseUp(.right, rel: .zero, dt: 0.5).dt, 0.5)
    }

    // MARK: - Helpers

    private func assertRoundTrip(_ action: AutoKeysAction, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(AutoKeysAction.self, from: data)
        XCTAssertEqual(decoded, action, file: file, line: line)
    }
}
