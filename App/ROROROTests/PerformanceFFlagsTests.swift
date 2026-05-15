// PerformanceFFlagsTests.swift
import XCTest
@testable import RORORO

final class PerformanceFFlagsTests: XCTestCase {

    func testBundle_NoPhysicsNetworkOrSimulationFlags() {
        // Same posture as LowResourceFFlags: render + telemetry only.
        // Physics/network/sim flags can break gameplay or trip anti-cheat.
        for key in PerformanceFFlags.bundle.keys {
            XCTAssertFalse(key.contains("Physics"), "Bundle includes physics flag: \(key)")
            XCTAssertFalse(key.contains("Network"), "Bundle includes network flag: \(key)")
            XCTAssertFalse(key.contains("RakNet"),  "Bundle includes RakNet flag: \(key)")
            XCTAssertFalse(key.contains("Sim") && !key.contains("Simulation"),
                           "Bundle includes simulation-tweak flag: \(key)")
        }
    }

    func testBundle_IsNonEmpty() {
        XCTAssertFalse(PerformanceFFlags.bundle.isEmpty)
    }

    func testBundle_DisablesPostFx_TheCoreFpsWin() {
        XCTAssertEqual(PerformanceFFlags.bundle["FFlagDisablePostFx"], .bool(true))
    }

    func testBundle_LighterThanLowResource_DoesNotForceLowestQuality() {
        // Performance keeps the game watchable — unlike LowResourceFFlags
        // it must NOT force the lowest render-quality preset.
        XCTAssertNil(PerformanceFFlags.bundle["DFIntDebugFRMQualityLevelOverride"],
                     "Performance bundle should not force lowest render quality")
    }
}
