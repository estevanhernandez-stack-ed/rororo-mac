// LaunchSettingsStoreTests.swift
// UserDefaults-backed snapshot of what the launch flow writes.

import XCTest
@testable import RORORO

@MainActor
final class LaunchSettingsStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "rororo-launch-settings-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - framerateCap

    func testFramerateCap_DefaultsToNil() {
        let store = LaunchSettingsStore(defaults: defaults)
        XCTAssertNil(store.framerateCap)
    }

    func testFramerateCap_PersistsAcrossInstances() {
        let store = LaunchSettingsStore(defaults: defaults)
        store.setFramerateCap(20)

        let reborn = LaunchSettingsStore(defaults: defaults)
        XCTAssertEqual(reborn.framerateCap, 20)
    }

    func testFramerateCap_ClearsWhenSetToNil() {
        let store = LaunchSettingsStore(defaults: defaults)
        store.setFramerateCap(20)
        store.setFramerateCap(nil)

        let reborn = LaunchSettingsStore(defaults: defaults)
        XCTAssertNil(reborn.framerateCap)
    }

    // MARK: - fflags

    func testFFlags_PersistsTypedValues() {
        let store = LaunchSettingsStore(defaults: defaults)
        store.setFFlags([
            "FFlagA": .bool(true),
            "DFIntB": .int(5),
            "FStringC": .string("metal"),
        ])

        let reborn = LaunchSettingsStore(defaults: defaults)
        XCTAssertEqual(reborn.fflags["FFlagA"], .bool(true))
        XCTAssertEqual(reborn.fflags["DFIntB"], .int(5))
        XCTAssertEqual(reborn.fflags["FStringC"], .string("metal"))
    }

    func testFFlags_EmptyClearsStorage() {
        let store = LaunchSettingsStore(defaults: defaults)
        store.setFFlags(["FFlagA": .bool(true)])
        store.setFFlags([:])

        let reborn = LaunchSettingsStore(defaults: defaults)
        XCTAssertTrue(reborn.fflags.isEmpty)
    }

    // MARK: - snapshot

    func testSnapshot_ReflectsCurrentState() {
        let store = LaunchSettingsStore(defaults: defaults)
        store.setFramerateCap(20)
        store.setFFlags(["FFlagDebugGraphicsPreferMetal": .bool(true)])

        let snapshot = store.snapshot()

        XCTAssertEqual(snapshot.framerateCap, 20)
        XCTAssertEqual(snapshot.fflags["FFlagDebugGraphicsPreferMetal"], .bool(true))
    }

    // MARK: - autoKeysLoopDelay (Slope C)

    func testAutoKeysLoopDelay_DefaultsTo14Min() {
        let store = LaunchSettingsStore(defaults: defaults)
        XCTAssertEqual(store.autoKeysLoopDelay, 14 * 60, accuracy: 0.001)
    }

    func testAutoKeysLoopDelay_PersistsAcrossInstances() {
        let store = LaunchSettingsStore(defaults: defaults)
        store.setAutoKeysLoopDelay(600)

        let reborn = LaunchSettingsStore(defaults: defaults)
        XCTAssertEqual(reborn.autoKeysLoopDelay, 600, accuracy: 0.001)
    }

    func testAutoKeysLoopDelay_ClampsBelowFloor() {
        let store = LaunchSettingsStore(defaults: defaults)
        store.setAutoKeysLoopDelay(5)
        // Floor is 30s — anything lower clamps up.
        XCTAssertEqual(store.autoKeysLoopDelay, 30, accuracy: 0.001)
    }

    func testAutoKeysLoopDelay_ClampsAboveCeiling() {
        let store = LaunchSettingsStore(defaults: defaults)
        store.setAutoKeysLoopDelay(60 * 60) // 1 hour
        // Ceiling is CycleBudget.hardCap = 19 * 60.
        XCTAssertEqual(store.autoKeysLoopDelay, CycleBudget.hardCap, accuracy: 0.001)
    }

    // MARK: - AnyCodableValue.jsonObject

    func testJsonObject_RoundTripsThroughJSONSerialization() throws {
        let flags: [String: AnyCodableValue] = [
            "Bool": .bool(true),
            "Int": .int(42),
            "Double": .double(1.5),
            "String": .string("vulkan"),
        ]
        let payload: [String: Any] = flags.mapValues { $0.jsonObject }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(decoded?["Bool"] as? Bool, true)
        XCTAssertEqual(decoded?["Int"] as? Int, 42)
        XCTAssertEqual(decoded?["Double"] as? Double, 1.5)
        XCTAssertEqual(decoded?["String"] as? String, "vulkan")
    }
}
