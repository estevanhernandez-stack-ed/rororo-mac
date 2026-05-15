// FFlagPresetIDTests.swift
import XCTest
@testable import RORORO

final class FFlagPresetIDTests: XCTestCase {

    func testAllCases_ContainsBothPresets() {
        XCTAssertEqual(Set(FFlagPresetID.allCases), [.lowResource, .performance])
    }

    func testCodable_RoundTripsThroughJSON() throws {
        for id in FFlagPresetID.allCases {
            let data = try JSONEncoder().encode(id)
            let decoded = try JSONDecoder().decode(FFlagPresetID.self, from: data)
            XCTAssertEqual(decoded, id)
        }
    }

    func testRawValue_IsStableWireString() {
        // The raw value is persisted to UserDefaults — renaming a case
        // without a migration would orphan a user's saved preset.
        XCTAssertEqual(FFlagPresetID.lowResource.rawValue, "lowResource")
        XCTAssertEqual(FFlagPresetID.performance.rawValue, "performance")
    }
}
