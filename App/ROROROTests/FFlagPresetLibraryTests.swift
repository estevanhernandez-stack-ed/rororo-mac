// FFlagPresetLibraryTests.swift
// Domain — registry shape + the launch-time merge semantics. The merge
// tests were previously in LowResourceFFlagsTests against
// LowResourceFFlags.merged(into:); they move here now that the merge is
// generalized to effectiveFlags(for:userOverrides:).

import XCTest
@testable import RORORO

final class FFlagPresetLibraryTests: XCTestCase {

    // MARK: - registry

    func testAll_ContainsExactlyTheRegisteredPresets() {
        XCTAssertEqual(FFlagPresetLibrary.all.map(\.id), [.lowResource, .performance])
    }

    func testPreset_ResolvesEveryID() {
        for id in FFlagPresetID.allCases {
            XCTAssertNotNil(FFlagPresetLibrary.preset(id), "No preset registered for \(id)")
        }
    }

    func testPreset_LowResource_WrapsLowResourceBundle() {
        XCTAssertEqual(FFlagPresetLibrary.preset(.lowResource)?.bundle.count,
                       LowResourceFFlags.bundle.count)
    }

    func testPreset_Performance_WrapsPerformanceBundle() {
        XCTAssertEqual(FFlagPresetLibrary.preset(.performance)?.bundle.count,
                       PerformanceFFlags.bundle.count)
    }

    // MARK: - effectiveFlags

    func testEffectiveFlags_NilPreset_ReturnsUserOverridesOnly() {
        let overrides: [String: AnyCodableValue] = ["FFlagA": .bool(true)]
        let result = FFlagPresetLibrary.effectiveFlags(for: nil, userOverrides: overrides)
        XCTAssertEqual(result, overrides)
    }

    func testEffectiveFlags_NilPresetEmptyOverrides_ReturnsEmpty() {
        let result = FFlagPresetLibrary.effectiveFlags(for: nil, userOverrides: [:])
        XCTAssertTrue(result.isEmpty)
    }

    func testEffectiveFlags_PresetOnly_ReturnsBundleAsIs() {
        let result = FFlagPresetLibrary.effectiveFlags(for: .lowResource, userOverrides: [:])
        XCTAssertEqual(result.count, LowResourceFFlags.bundle.count)
        XCTAssertEqual(result["FFlagDisablePostFx"], .bool(true))
    }

    func testEffectiveFlags_UserOverrideWinsOnCollision() {
        // LowResourceFFlags sets DFIntDebugFRMQualityLevelOverride to 1.
        // A user override of 10 MUST win.
        let result = FFlagPresetLibrary.effectiveFlags(
            for: .lowResource,
            userOverrides: ["DFIntDebugFRMQualityLevelOverride": .int(10)]
        )
        XCTAssertEqual(result["DFIntDebugFRMQualityLevelOverride"], .int(10))
    }

    func testEffectiveFlags_UserOverrideNotInBundle_AddedAlongside() {
        let result = FFlagPresetLibrary.effectiveFlags(
            for: .lowResource,
            userOverrides: ["FFlagSomeUserSpecificThing": .bool(true)]
        )
        XCTAssertEqual(result["FFlagSomeUserSpecificThing"], .bool(true))
        XCTAssertEqual(result["FFlagDisablePostFx"], .bool(true))
        XCTAssertEqual(result.count, LowResourceFFlags.bundle.count + 1)
    }
}
