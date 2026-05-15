// RiskyFFlagPatternsTests.swift
import XCTest
@testable import RORORO

final class RiskyFFlagPatternsTests: XCTestCase {

    func testRisk_PhysicsFlag_FlaggedAsPhysics() {
        XCTAssertEqual(RiskyFFlagPatterns.risk(for: "DFIntPhysicsSenderRate"), .physics)
    }

    func testRisk_NetworkFlag_FlaggedAsNetwork() {
        XCTAssertEqual(RiskyFFlagPatterns.risk(for: "FFlagDebugNetworkBandwidthLog"), .network)
    }

    func testRisk_RakNetFlag_FlaggedAsNetwork() {
        XCTAssertEqual(RiskyFFlagPatterns.risk(for: "DFIntRakNetResendBufferArrayLength"), .network)
    }

    func testRisk_SimulationFlag_FlaggedAsSimulation() {
        XCTAssertEqual(RiskyFFlagPatterns.risk(for: "DFIntSimulationRadius"), .simulation)
    }

    func testRisk_SafeRenderFlags_NotFlagged() {
        XCTAssertNil(RiskyFFlagPatterns.risk(for: "FFlagDisablePostFx"))
        XCTAssertNil(RiskyFFlagPatterns.risk(for: "FFlagDebugGraphicsPreferMetal"))
        XCTAssertNil(RiskyFFlagPatterns.risk(for: "DFIntTextureQualityOverride"))
    }

    func testRisk_MatchIsCaseInsensitive() {
        XCTAssertEqual(RiskyFFlagPatterns.risk(for: "fflagsomephysicsthing"), .physics)
    }

    func testRisk_NoFalsePositiveAgainstShippedBundles() {
        // Neither curated bundle should trip the matcher — they are
        // render + telemetry only by design.
        for key in LowResourceFFlags.bundle.keys {
            XCTAssertNil(RiskyFFlagPatterns.risk(for: key), "False positive on \(key)")
        }
        for key in PerformanceFFlags.bundle.keys {
            XCTAssertNil(RiskyFFlagPatterns.risk(for: key), "False positive on \(key)")
        }
    }
}
