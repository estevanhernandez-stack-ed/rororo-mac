// FFlagsSheetTests.swift
// UI — the FFlagsSheet view itself follows the project's untested-view
// pattern, but its editor model (the pure rawValue <-> AnyCodableValue
// translation) is logic worth locking down.

import XCTest
@testable import RORORO

final class FFlagsSheetTests: XCTestCase {

    func testRowsFromStore_MapsEachTypeToRawText() {
        let rows = FFlagsSheet.rowsFromStore([
            "FFlagB": .bool(true),
            "DFIntI": .int(7),
            "DFNumD": .double(1.5),
            "FStringS": .string("metal"),
        ])
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0) })
        XCTAssertEqual(byKey["FFlagB"]?.type, .bool)
        XCTAssertEqual(byKey["FFlagB"]?.rawValue, "true")
        XCTAssertEqual(byKey["DFIntI"]?.type, .int)
        XCTAssertEqual(byKey["DFIntI"]?.rawValue, "7")
        XCTAssertEqual(byKey["DFNumD"]?.type, .double)
        XCTAssertEqual(byKey["FStringS"]?.type, .string)
        XCTAssertEqual(byKey["FStringS"]?.rawValue, "metal")
    }

    func testRowsFromStore_SortedByKey() {
        let rows = FFlagsSheet.rowsFromStore(["ZFlag": .bool(true), "AFlag": .bool(false)])
        XCTAssertEqual(rows.map(\.key), ["AFlag", "ZFlag"])
    }

    func testStoreFromRows_RoundTripsValidRows() {
        let original: [String: AnyCodableValue] = [
            "FFlagB": .bool(false),
            "DFIntI": .int(42),
        ]
        let rebuilt = FFlagsSheet.storeFromRows(FFlagsSheet.rowsFromStore(original))
        XCTAssertEqual(rebuilt, original)
    }

    func testStoreFromRows_DropsEmptyKey() {
        let rows = [FFlagsSheet.EditorRow(key: "", type: .bool, rawValue: "true")]
        XCTAssertTrue(FFlagsSheet.storeFromRows(rows).isEmpty)
    }

    func testStoreFromRows_DropsUnparseableValue() {
        let rows = [FFlagsSheet.EditorRow(key: "DFIntI", type: .int, rawValue: "not-a-number")]
        XCTAssertTrue(FFlagsSheet.storeFromRows(rows).isEmpty)
    }

    func testStoreFromRows_DuplicateKey_LastWins() {
        let rows = [
            FFlagsSheet.EditorRow(key: "FFlagB", type: .bool, rawValue: "true"),
            FFlagsSheet.EditorRow(key: "FFlagB", type: .bool, rawValue: "false"),
        ]
        XCTAssertEqual(FFlagsSheet.storeFromRows(rows), ["FFlagB": .bool(false)])
    }

    func testParsedValue_BoolRejectsNonBoolText() {
        let row = FFlagsSheet.EditorRow(key: "FFlagB", type: .bool, rawValue: "yes")
        XCTAssertNil(FFlagsSheet.parsedValue(for: row))
    }

    func testParseError_EmptyKey_ReportsError() {
        let row = FFlagsSheet.EditorRow(key: "", type: .string, rawValue: "x")
        XCTAssertEqual(FFlagsSheet.parseError(for: row), "Flag name can't be empty.")
    }

    func testParseError_ValidRow_ReturnsNil() {
        let row = FFlagsSheet.EditorRow(key: "FFlagB", type: .bool, rawValue: "true")
        XCTAssertNil(FFlagsSheet.parseError(for: row))
    }

    func testParseError_BadInt_ReportsError() {
        let row = FFlagsSheet.EditorRow(key: "DFIntI", type: .int, rawValue: "1.5")
        XCTAssertEqual(FFlagsSheet.parseError(for: row), "Not a whole number.")
    }
}
