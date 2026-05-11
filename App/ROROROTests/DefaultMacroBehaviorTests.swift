// DefaultMacroBehaviorTests.swift
// Wave D-3.8 — tagged Codable shape for the global-default-macro
// setting. Pins the on-disk form so a future enum-case add can't
// silently invalidate existing settings.

import XCTest
@testable import RORORO

final class DefaultMacroBehaviorTests: XCTestCase {

    func testRoundTrip_Skip() throws {
        try assertRoundTrip(.skip)
    }

    func testRoundTrip_StayAlive() throws {
        try assertRoundTrip(.stayAlive)
    }

    func testRoundTrip_UseShared() throws {
        try assertRoundTrip(.useShared(sourceUserId: "12345"))
    }

    func testEncodedSkip_DoesNotEmitSourceUserId() throws {
        let data = try JSONEncoder().encode(DefaultMacroBehavior.skip)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["kind"] as? String, "skip")
        XCTAssertNil(dict["sourceUserId"])
    }

    func testEncodedStayAlive_DoesNotEmitSourceUserId() throws {
        let data = try JSONEncoder().encode(DefaultMacroBehavior.stayAlive)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["kind"] as? String, "stayAlive")
        XCTAssertNil(dict["sourceUserId"])
    }

    func testEncodedUseShared_CarriesSourceUserId() throws {
        let data = try JSONEncoder().encode(DefaultMacroBehavior.useShared(sourceUserId: "abc"))
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["kind"] as? String, "useShared")
        XCTAssertEqual(dict["sourceUserId"] as? String, "abc")
    }

    // MARK: - Helpers

    private func assertRoundTrip(
        _ behavior: DefaultMacroBehavior,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try JSONEncoder().encode(behavior)
        let decoded = try JSONDecoder().decode(DefaultMacroBehavior.self, from: data)
        XCTAssertEqual(decoded, behavior, file: file, line: line)
    }
}
