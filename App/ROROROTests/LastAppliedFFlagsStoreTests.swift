// LastAppliedFFlagsStoreTests.swift
// Domain — last-launch FFlag snapshot persistence, including ADR 0011's
// activePreset field swap and tolerant decode of pre-ADR-0011 records.

import XCTest
@testable import RORORO

@MainActor
final class LastAppliedFFlagsStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "rororo-last-fflags-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func testRecord_PersistsActivePresetAcrossInstances() {
        let store = LastAppliedFFlagsStore(defaults: defaults)
        let snap = LastAppliedFFlagsStore.Snapshot(
            appliedAt: Date(timeIntervalSince1970: 1_700_000_000),
            activePreset: .performance,
            flags: ["FFlagDisablePostFx": .bool(true)],
            outcome: "createdFresh"
        )
        store.record(snap)

        let reborn = LastAppliedFFlagsStore(defaults: defaults)
        XCTAssertEqual(reborn.lastSnapshot, snap)
        XCTAssertEqual(reborn.lastSnapshot?.activePreset, .performance)
    }

    func testRecord_NilActivePreset_RoundTrips() {
        let store = LastAppliedFFlagsStore(defaults: defaults)
        let snap = LastAppliedFFlagsStore.Snapshot(
            appliedAt: Date(timeIntervalSince1970: 1_700_000_000),
            activePreset: nil,
            flags: [:],
            outcome: "createdFresh"
        )
        store.record(snap)

        let reborn = LastAppliedFFlagsStore(defaults: defaults)
        XCTAssertNotNil(reborn.lastSnapshot)
        XCTAssertNil(reborn.lastSnapshot?.activePreset)
    }

    func testDecode_LegacyPreADR0011Record_DecodesWithNilActivePreset() throws {
        // A snapshot persisted before ADR 0011 carries `lowResourceMode`
        // (Bool) and no `activePreset`. The new optional field decodes to
        // nil via decodeIfPresent; the stale `lowResourceMode` key is
        // ignored. No crash, no data loss beyond the (non-load-bearing)
        // preset name. `appliedAt` is ISO8601 — the store's decoder uses
        // `.iso8601`.
        let legacyJSON = """
        {
          "appliedAt": "2023-11-14T22:13:20Z",
          "lowResourceMode": true,
          "flags": { "FFlagDisablePostFx": true },
          "outcome": "createdFresh"
        }
        """.data(using: .utf8)!
        defaults.set(legacyJSON, forKey: "rororo.diagnostics.lastFFlagSnapshot")

        let store = LastAppliedFFlagsStore(defaults: defaults)
        XCTAssertNotNil(store.lastSnapshot, "Legacy record should still decode")
        XCTAssertNil(store.lastSnapshot?.activePreset)
        XCTAssertEqual(store.lastSnapshot?.outcome, "createdFresh")
    }
}
