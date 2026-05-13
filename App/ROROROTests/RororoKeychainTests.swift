// RororoKeychainTests.swift
// Targets temp-path keychains so the dev's login keychain stays clean.
// IMPORTANT: prependToSearchList prompts the user for password the
// first time the test runs on a fresh dev machine. Enter password once;
// subsequent runs in the same session are silent. This is unavoidable —
// macOS requires authorization to modify the keychain search list.

import XCTest
@testable import RORORO

final class RororoKeychainTests: XCTestCase {

    private var tempPath: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Even non-search-list-modifying tests in this class hang on
        // headless CI — RororoKeychain.create runs `security create-
        // keychain` + `security set-keychain-settings` + `security
        // unlock-keychain`, and at least one of those prompts the user
        // to confirm keychain modification on a fresh CI runner.
        // Blanket-skip the whole class; opt-in locally via
        // RORORO_RUN_KEYCHAIN_AUTH_TESTS=1 so the developer accepts
        // the prompts knowingly.
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RORORO_RUN_KEYCHAIN_AUTH_TESTS"] != nil,
            "Opt-in only — set RORORO_RUN_KEYCHAIN_AUTH_TESTS=1 locally to exercise"
        )
        tempPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rororo-keychain-test-\(UUID().uuidString).keychain")
    }

    override func tearDown() {
        try? RororoKeychain.removeFromSearchListIfPresent(keychainPath: tempPath)
        try? RororoKeychain.delete(keychainPath: tempPath)
        super.tearDown()
    }

    func testCreateMakesKeychainFile() throws {
        try RororoKeychain.create(keychainPath: tempPath, password: "")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: tempPath.path),
            "create-keychain should produce a file at the requested path"
        )
    }

    func testUnlockAfterCreateSucceeds() throws {
        try RororoKeychain.create(keychainPath: tempPath, password: "")
        XCTAssertNoThrow(
            try RororoKeychain.unlock(keychainPath: tempPath, password: "")
        )
    }

    func testPrependToSearchListPutsKeychainFirst() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RORORO_RUN_KEYCHAIN_AUTH_TESTS"] != nil,
            "Opt-in only — set RORORO_RUN_KEYCHAIN_AUTH_TESTS=1 locally to exercise"
        )
        try RororoKeychain.create(keychainPath: tempPath, password: "")
        let priorList = try RororoKeychain.currentSearchList()

        try RororoKeychain.prependToSearchList(keychainPath: tempPath)

        let newList = try RororoKeychain.currentSearchList()
        XCTAssertEqual(
            newList.first, RororoKeychain.canonicalPath(for: tempPath),
            "freshly added keychain should be first in the search list"
        )
        XCTAssertEqual(
            newList.count, priorList.count + 1,
            "search list should grow by exactly one entry"
        )
    }

    func testPrependIsIdempotent() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RORORO_RUN_KEYCHAIN_AUTH_TESTS"] != nil,
            "Opt-in only — set RORORO_RUN_KEYCHAIN_AUTH_TESTS=1 locally to exercise"
        )
        try RororoKeychain.create(keychainPath: tempPath, password: "")
        try RororoKeychain.prependToSearchList(keychainPath: tempPath)
        let firstList = try RororoKeychain.currentSearchList()

        try RororoKeychain.prependToSearchList(keychainPath: tempPath)
        let secondList = try RororoKeychain.currentSearchList()

        XCTAssertEqual(
            firstList, secondList,
            "re-prepending the same path should not change the list"
        )
    }
}
