// MacroTests.swift
// Wave D-4.1 — first-class macro entity. Covers normalization +
// Codable round-trip.

import XCTest
@testable import RORORO

final class MacroTests: XCTestCase {

    func testInit_TrimsName() {
        let m = Macro(
            name: "  Combat rotation  ",
            variant: .stream([.keyDown(keyCode: 49, modifiers: 0, dt: 0)])
        )
        XCTAssertEqual(m.name, "Combat rotation")
    }

    func testInit_EmptyName_FallsBackToUntitledForStream() {
        let m = Macro(
            name: "",
            variant: .stream([.keyDown(keyCode: 49, modifiers: 0, dt: 0)])
        )
        XCTAssertEqual(m.name, "Untitled")
    }

    func testInit_EmptyName_FallsBackToUntitledLegacyForLegacyVariant() {
        let m = Macro(
            name: "",
            variant: .legacy([.spacebar()])
        )
        XCTAssertEqual(m.name, "Untitled (legacy)")
    }

    func testInit_DefaultIsSharedTrue() {
        let m = Macro(
            name: "x",
            variant: .stream([])
        )
        XCTAssertTrue(m.isShared)
    }

    func testRoundTrip_PreservesAllFields() throws {
        let original = Macro(
            id: "fixed-id",
            name: "Combat",
            ownerUserId: "12345",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            variant: .stream([.keyDown(keyCode: 49, modifiers: 0, dt: 0)]),
            isShared: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Macro.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testSequence_ExtractsVariantWithSharingAndName() {
        let m = Macro(
            name: "Test",
            variant: .stream([.keyDown(keyCode: 49, modifiers: 0, dt: 0)]),
            isShared: true
        )
        let seq = m.sequence
        XCTAssertTrue(seq.isStream)
        XCTAssertTrue(seq.isShared)
        XCTAssertEqual(seq.name, "Test")
    }
}
