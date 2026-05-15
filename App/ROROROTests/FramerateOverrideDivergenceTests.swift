import XCTest
@testable import RORORO

final class FramerateOverrideDivergenceTests: XCTestCase {

    func testDiverges_NoOverride_ReturnsFalse() {
        // No override at all — there is nothing to flag.
        XCTAssertFalse(FramerateOverrideDivergence.diverges(override: nil, global: 144))
    }

    func testDiverges_OverrideSetGlobalNil_ReturnsFalse() {
        // No global to compare against — the override is "your only opinion."
        XCTAssertFalse(FramerateOverrideDivergence.diverges(override: 20, global: nil))
    }

    func testDiverges_OverrideMatchesGlobal_ReturnsFalse() {
        // The override happens to match the global — applying it changes
        // nothing. No surprise to surface.
        XCTAssertFalse(FramerateOverrideDivergence.diverges(override: 20, global: 20))
    }

    func testDiverges_OverrideDiffersFromGlobal_ReturnsTrue() {
        // Override silently overrides the global on launch — this is the
        // trap the badge surfaces.
        XCTAssertTrue(FramerateOverrideDivergence.diverges(override: 20, global: 144))
    }
}
