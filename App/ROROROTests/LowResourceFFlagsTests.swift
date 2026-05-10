// LowResourceFFlagsTests.swift
// Domain — verifies the merge logic. Bundle contents are documented in
// ADR 0006; we don't snapshot-test the bundle since it's expected to
// evolve. We DO test that user-set fflags win on overlap and that the
// merge doesn't lose entries.

import XCTest
@testable import RORORO

final class LowResourceFFlagsTests: XCTestCase {

    // MARK: - merge

    func testMerge_EmptyUserFlags_ReturnsBundleAsIs() {
        let merged = LowResourceFFlags.merged(into: [:])
        XCTAssertEqual(merged.count, LowResourceFFlags.bundle.count)
        // Spot-check a known bundle entry survives.
        XCTAssertEqual(merged["FFlagDisablePostFx"], .bool(true))
    }

    func testMerge_UserFlagOverridesBundle_UserWins() {
        // Bundle sets DFIntDebugFRMQualityLevelOverride to 1 (lowest).
        // User explicitly sets it to 10 (highest). User MUST win.
        let userFlags: [String: AnyCodableValue] = [
            "DFIntDebugFRMQualityLevelOverride": .int(10)
        ]
        let merged = LowResourceFFlags.merged(into: userFlags)
        XCTAssertEqual(merged["DFIntDebugFRMQualityLevelOverride"], .int(10))
    }

    func testMerge_UserFlagNotInBundle_AddedAlongside() {
        let userFlags: [String: AnyCodableValue] = [
            "FFlagSomeUserSpecificThing": .bool(true)
        ]
        let merged = LowResourceFFlags.merged(into: userFlags)
        XCTAssertEqual(merged["FFlagSomeUserSpecificThing"], .bool(true))
        // Bundle entries still present.
        XCTAssertEqual(merged["FFlagDisablePostFx"], .bool(true))
        XCTAssertEqual(merged.count, LowResourceFFlags.bundle.count + 1)
    }

    func testMerge_MultipleUserOverrides_AllWin() {
        let userFlags: [String: AnyCodableValue] = [
            "FFlagDisablePostFx": .bool(false),                       // bundle says true → user wins false
            "DFIntTextureQualityOverride": .int(3),                   // bundle says 1 → user wins 3
            "FFlagDebugDisableTelemetryV2Stat": .bool(false),         // bundle says true → user wins false
        ]
        let merged = LowResourceFFlags.merged(into: userFlags)
        XCTAssertEqual(merged["FFlagDisablePostFx"], .bool(false))
        XCTAssertEqual(merged["DFIntTextureQualityOverride"], .int(3))
        XCTAssertEqual(merged["FFlagDebugDisableTelemetryV2Stat"], .bool(false))
        // Other bundle entries unchanged.
        XCTAssertEqual(merged["FIntRenderShadowIntensity"], .int(0))
    }

    // MARK: - bundle invariants

    func testBundle_NoPhysicsOrNetworkFlags() {
        // The bundle posture is render-only + telemetry. Physics flags
        // can break gameplay; network flags can trigger anti-cheat in
        // some titles. None should appear in the bundle.
        for key in LowResourceFFlags.bundle.keys {
            XCTAssertFalse(key.contains("Physics"), "Bundle includes physics flag: \(key)")
            XCTAssertFalse(key.contains("Network"), "Bundle includes network flag: \(key)")
            XCTAssertFalse(key.contains("RakNet"),  "Bundle includes RakNet (network) flag: \(key)")
            XCTAssertFalse(key.contains("Sim") && !key.contains("Simulation"),
                           "Bundle includes simulation-tweak flag: \(key)")
        }
    }

    func testBundle_ContainsCoreLowResourceFlags() {
        // Sanity: the load-bearing render-cost flags from the
        // "Absolutely kills your game graphics" combination must be
        // present; if any are missing, the bundle's value drops.
        let mustHave = [
            "DFFlagDebugRenderForceTechnologyVoxel",
            "DFIntDebugFRMQualityLevelOverride",
            "FFlagDisablePostFx",
            "FIntRenderShadowIntensity",
            "DFIntTextureQualityOverride",
        ]
        for key in mustHave {
            XCTAssertNotNil(LowResourceFFlags.bundle[key],
                            "Bundle missing core low-resource flag: \(key)")
        }
    }
}
