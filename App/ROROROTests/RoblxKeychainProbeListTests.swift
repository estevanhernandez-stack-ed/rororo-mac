// RoblxKeychainProbeListTests.swift
// Pin test: the probe list must include SharedROBLOSECURITYForStudio
// (the one item observed in the live dump 2026-05-12). If a refactor
// deletes the list or empties it, this catches the regression before
// it ships to users.

import XCTest
@testable import RORORO

final class RoblxKeychainProbeListTests: XCTestCase {

    func testListIsNotEmpty() {
        XCTAssertFalse(
            RoblxKeychainProbeList.items.isEmpty,
            "probe list must include at least the SharedROBLOSECURITYForStudio entry"
        )
    }

    func testListIncludesSharedROBLOSECURITYForStudio() {
        let matches = RoblxKeychainProbeList.items.filter {
            $0.account == "https://www.roblox.com/:SharedROBLOSECURITYForStudio"
        }
        XCTAssertEqual(matches.count, 1, "exactly one entry for SharedROBLOSECURITYForStudio")
        let item = matches.first
        XCTAssertEqual(item?.kind, .genericPassword)
        XCTAssertEqual(item?.service, "https://www.roblox.com/:SharedROBLOSECURITYForStudio")
    }
}
