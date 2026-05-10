// WindowLayoutPlannerTests.swift
// Pure planner — table-driven tests for grid + shrink math.
// No AppKit / AX dependency; all assertions on CGRect math.

import XCTest
@testable import RORORO

final class WindowLayoutPlannerTests: XCTestCase {

    /// 1280×800 visible rect at origin (0, 0). Used by most cases unless
    /// the test explicitly varies geometry.
    private let standardRect = CGRect(x: 0, y: 0, width: 1280, height: 800)

    // MARK: - autoGrid

    func testAutoGrid_N4_Yields2x2() {
        let pids: [pid_t] = [101, 102, 103, 104]
        let plan = WindowLayoutPlanner.plan(
            mode: .autoGrid,
            pids: pids,
            visibleRect: standardRect,
            currentFrames: [:]
        )
        // 2×2 → cell is 640×400. Sorted-by-pid fills row-major:
        // 101→top-left, 102→top-right, 103→bottom-left, 104→bottom-right.
        XCTAssertEqual(plan[101], CGRect(x: 0,   y: 0,   width: 640, height: 400))
        XCTAssertEqual(plan[102], CGRect(x: 640, y: 0,   width: 640, height: 400))
        XCTAssertEqual(plan[103], CGRect(x: 0,   y: 400, width: 640, height: 400))
        XCTAssertEqual(plan[104], CGRect(x: 640, y: 400, width: 640, height: 400))
    }

    func testAutoGrid_N1_Yields1x1_FullScreen() {
        let plan = WindowLayoutPlanner.plan(
            mode: .autoGrid, pids: [10], visibleRect: standardRect, currentFrames: [:]
        )
        XCTAssertEqual(plan[10], standardRect)
    }

    func testAutoGrid_N2_YieldsTwoColumns() {
        let plan = WindowLayoutPlanner.plan(
            mode: .autoGrid, pids: [10, 20], visibleRect: standardRect, currentFrames: [:]
        )
        // ceil(sqrt(2)) = 2 cols, ceil(2/2) = 1 row → 2×1.
        XCTAssertEqual(plan[10], CGRect(x: 0,   y: 0, width: 640, height: 800))
        XCTAssertEqual(plan[20], CGRect(x: 640, y: 0, width: 640, height: 800))
    }

    func testAutoGrid_N3_Yields2x2_OneCellEmpty() {
        let plan = WindowLayoutPlanner.plan(
            mode: .autoGrid, pids: [10, 20, 30], visibleRect: standardRect, currentFrames: [:]
        )
        // ceil(sqrt(3)) = 2 cols, ceil(3/2) = 2 rows → 2×2 with bottom-right empty.
        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(plan[10], CGRect(x: 0,   y: 0,   width: 640, height: 400))
        XCTAssertEqual(plan[20], CGRect(x: 640, y: 0,   width: 640, height: 400))
        XCTAssertEqual(plan[30], CGRect(x: 0,   y: 400, width: 640, height: 400))
    }

    func testAutoGrid_N5_Yields3x2_OneCellEmpty() {
        let pids: [pid_t] = [1, 2, 3, 4, 5]
        let plan = WindowLayoutPlanner.plan(
            mode: .autoGrid, pids: pids, visibleRect: standardRect, currentFrames: [:]
        )
        // ceil(sqrt(5)) = 3 cols, ceil(5/3) = 2 rows. Cell 1280/3 × 400.
        XCTAssertEqual(plan.count, 5)
        let expectedW = standardRect.width / 3.0
        XCTAssertEqual(plan[1]!.width,  expectedW, accuracy: 0.001)
        XCTAssertEqual(plan[1]!.height, 400,       accuracy: 0.001)
        // pid 5 lands at row 1 col 1 (second row, middle column).
        XCTAssertEqual(plan[5]!.origin.x, expectedW,     accuracy: 0.001)
        XCTAssertEqual(plan[5]!.origin.y, 400,           accuracy: 0.001)
    }

    func testAutoGrid_N9_Yields3x3() {
        let pids: [pid_t] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
        let plan = WindowLayoutPlanner.plan(
            mode: .autoGrid, pids: pids, visibleRect: standardRect, currentFrames: [:]
        )
        XCTAssertEqual(plan.count, 9)
        // Every cell should be 1280/3 × 800/3.
        for pid in pids {
            XCTAssertEqual(plan[pid]!.width,  standardRect.width  / 3, accuracy: 0.001)
            XCTAssertEqual(plan[pid]!.height, standardRect.height / 3, accuracy: 0.001)
        }
    }

    func testAutoGrid_EmptyPids_YieldsEmptyPlan() {
        let plan = WindowLayoutPlanner.plan(
            mode: .autoGrid, pids: [], visibleRect: standardRect, currentFrames: [:]
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testAutoGrid_RespectsVisibleRectOrigin() {
        // Simulate menu bar present (y origin > 0).
        let offsetRect = CGRect(x: 0, y: 25, width: 1280, height: 775)
        let plan = WindowLayoutPlanner.plan(
            mode: .autoGrid, pids: [10, 20, 30, 40], visibleRect: offsetRect, currentFrames: [:]
        )
        // Top-left cell should start at the offset origin, not (0, 0).
        XCTAssertEqual(plan[10]!.origin.x, 0,  accuracy: 0.001)
        XCTAssertEqual(plan[10]!.origin.y, 25, accuracy: 0.001)
    }

    // MARK: - explicit grid

    func testGrid_3x3_WithN5_FillsRowMajor() {
        let pids: [pid_t] = [1, 2, 3, 4, 5]
        let plan = WindowLayoutPlanner.plan(
            mode: .grid(cols: 3, rows: 3),
            pids: pids,
            visibleRect: standardRect,
            currentFrames: [:]
        )
        // Cell: 1280/3 × 800/3. Row-major: 1→(0,0), 2→(427, 0), 3→(853, 0),
        // 4→(0, 267), 5→(427, 267).
        XCTAssertEqual(plan.count, 5)
        let cellW = standardRect.width / 3.0
        let cellH = standardRect.height / 3.0
        XCTAssertEqual(plan[1]!.origin.x, 0,            accuracy: 0.001)
        XCTAssertEqual(plan[1]!.origin.y, 0,            accuracy: 0.001)
        XCTAssertEqual(plan[5]!.origin.x, cellW,        accuracy: 0.001)
        XCTAssertEqual(plan[5]!.origin.y, cellH,        accuracy: 0.001)
    }

    func testGrid_RowMode_1xN_StretchesAcross() {
        let pids: [pid_t] = [1, 2, 3, 4]
        let plan = WindowLayoutPlanner.plan(
            mode: .grid(cols: 4, rows: 1),
            pids: pids,
            visibleRect: standardRect,
            currentFrames: [:]
        )
        // Each cell: 320×800.
        for pid in pids {
            XCTAssertEqual(plan[pid]!.height, 800, accuracy: 0.001)
            XCTAssertEqual(plan[pid]!.width,  320, accuracy: 0.001)
        }
    }

    func testGrid_ColumnMode_Nx1_StacksVertically() {
        let pids: [pid_t] = [1, 2, 3, 4]
        let plan = WindowLayoutPlanner.plan(
            mode: .grid(cols: 1, rows: 4),
            pids: pids,
            visibleRect: standardRect,
            currentFrames: [:]
        )
        // Each cell: 1280×200.
        for pid in pids {
            XCTAssertEqual(plan[pid]!.width,  1280, accuracy: 0.001)
            XCTAssertEqual(plan[pid]!.height, 200,  accuracy: 0.001)
        }
    }

    func testGrid_OverflowDropsExtraPids() {
        // 2×2 grid = 4 cells, but 5 pids → last one drops.
        let pids: [pid_t] = [1, 2, 3, 4, 5]
        let plan = WindowLayoutPlanner.plan(
            mode: .grid(cols: 2, rows: 2),
            pids: pids,
            visibleRect: standardRect,
            currentFrames: [:]
        )
        XCTAssertEqual(plan.count, 4)
        XCTAssertNil(plan[5])  // pid 5 has no cell
    }

    func testGrid_StableSortByPid() {
        // Plan twice with same input, expect identical output.
        let pids: [pid_t] = [9999, 1, 500, 42]
        let a = WindowLayoutPlanner.plan(
            mode: .grid(cols: 2, rows: 2), pids: pids,
            visibleRect: standardRect, currentFrames: [:]
        )
        let b = WindowLayoutPlanner.plan(
            mode: .grid(cols: 2, rows: 2), pids: pids,
            visibleRect: standardRect, currentFrames: [:]
        )
        XCTAssertEqual(a, b)
        // pid 1 (smallest) should be at origin.
        XCTAssertEqual(a[1]!.origin, .zero)
    }

    // MARK: - shrink

    func testShrink_50Percent_PreservesCenter() {
        // Window at (200, 100, 1280, 720) → center (840, 460).
        // 50% shrink → (640×360) centered on (840, 460) → (520, 280).
        let current: [pid_t: CGRect] = [
            42: CGRect(x: 200, y: 100, width: 1280, height: 720)
        ]
        let plan = WindowLayoutPlanner.plan(
            mode: .shrink(percent: 0.5),
            pids: [42],
            visibleRect: standardRect,
            currentFrames: current
        )
        XCTAssertEqual(plan[42], CGRect(x: 520, y: 280, width: 640, height: 360))
    }

    func testShrink_25Percent_QuarterSize() {
        let current: [pid_t: CGRect] = [
            7: CGRect(x: 0, y: 0, width: 800, height: 600)
        ]
        let plan = WindowLayoutPlanner.plan(
            mode: .shrink(percent: 0.25),
            pids: [7],
            visibleRect: standardRect,
            currentFrames: current
        )
        // Center of (0,0,800,600) = (400, 300). 25% → 200×150 around (400, 300)
        // → origin (300, 225).
        XCTAssertEqual(plan[7], CGRect(x: 300, y: 225, width: 200, height: 150))
    }

    func testShrink_100Percent_NoOp() {
        let current: [pid_t: CGRect] = [
            1: CGRect(x: 50, y: 50, width: 400, height: 300)
        ]
        let plan = WindowLayoutPlanner.plan(
            mode: .shrink(percent: 1.0),
            pids: [1],
            visibleRect: standardRect,
            currentFrames: current
        )
        XCTAssertEqual(plan[1], current[1])
    }

    func testShrink_PidWithoutCurrentFrame_IsSkipped() {
        // Pid is in the input list but we have no current frame for it →
        // planner can't compute a shrink, drops it.
        let plan = WindowLayoutPlanner.plan(
            mode: .shrink(percent: 0.5),
            pids: [10, 20],
            visibleRect: standardRect,
            currentFrames: [10: CGRect(x: 0, y: 0, width: 100, height: 100)]
        )
        XCTAssertEqual(plan.count, 1)
        XCTAssertNotNil(plan[10])
        XCTAssertNil(plan[20])
    }

    func testShrink_MultipleWindows_EachPreservesOwnCenter() {
        let current: [pid_t: CGRect] = [
            1: CGRect(x: 0,   y: 0,   width: 200, height: 200),  // center (100, 100)
            2: CGRect(x: 500, y: 500, width: 400, height: 400),  // center (700, 700)
        ]
        let plan = WindowLayoutPlanner.plan(
            mode: .shrink(percent: 0.5),
            pids: [1, 2],
            visibleRect: standardRect,
            currentFrames: current
        )
        // pid 1 → 100×100 around (100, 100) → (50, 50, 100, 100)
        XCTAssertEqual(plan[1], CGRect(x: 50, y: 50, width: 100, height: 100))
        // pid 2 → 200×200 around (700, 700) → (600, 600, 200, 200)
        XCTAssertEqual(plan[2], CGRect(x: 600, y: 600, width: 200, height: 200))
    }
}
