// LowResourceFFlagsTests.swift
// Domain — verifies the LowResourceFFlags bundle invariants. The merge
// logic moved to FFlagPresetLibrary (ADR 0011); see FFlagPresetLibraryTests.

import XCTest
@testable import RORORO

final class LowResourceFFlagsTests: XCTestCase {

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
