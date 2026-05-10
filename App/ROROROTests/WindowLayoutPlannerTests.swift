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

    // MARK: - cascade

    func testCascade_FirstPidAtOrigin() {
        // Single window starts at visibleRect.origin with current size.
        let current: [pid_t: CGRect] = [
            42: CGRect(x: 200, y: 100, width: 1024, height: 768)
        ]
        let plan = WindowLayoutPlanner.plan(
            mode: .cascade(),
            pids: [42],
            visibleRect: standardRect,
            currentFrames: current
        )
        XCTAssertEqual(plan[42], CGRect(x: 0, y: 0, width: 1024, height: 768))
    }

    func testCascade_StaircaseOffset40x40() {
        // Three windows, each offset 40x40 from the previous.
        let current: [pid_t: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 800, height: 600),
            2: CGRect(x: 0, y: 0, width: 800, height: 600),
            3: CGRect(x: 0, y: 0, width: 800, height: 600),
        ]
        let plan = WindowLayoutPlanner.plan(
            mode: .cascade(),
            pids: [1, 2, 3],
            visibleRect: standardRect,
            currentFrames: current
        )
        XCTAssertEqual(plan[1]!.origin, CGPoint(x: 0,  y: 0))
        XCTAssertEqual(plan[2]!.origin, CGPoint(x: 40, y: 40))
        XCTAssertEqual(plan[3]!.origin, CGPoint(x: 80, y: 80))
    }

    func testCascade_PreservesCurrentSize() {
        // Each window's current size flows through to the cascaded frame —
        // no resize, position-only.
        let current: [pid_t: CGRect] = [
            1: CGRect(x: 0,   y: 0,   width: 800,  height: 600),
            2: CGRect(x: 100, y: 100, width: 1280, height: 720),
        ]
        let plan = WindowLayoutPlanner.plan(
            mode: .cascade(),
            pids: [1, 2],
            visibleRect: standardRect,
            currentFrames: current
        )
        XCTAssertEqual(plan[1]!.size, CGSize(width: 800,  height: 600))
        XCTAssertEqual(plan[2]!.size, CGSize(width: 1280, height: 720))
    }

    func testCascade_FallsBackToDefaultSizeIfNoCurrentFrame() {
        // External Roblox window we couldn't probe — planner uses the
        // 1024x768 default so the layout still produces something.
        let plan = WindowLayoutPlanner.plan(
            mode: .cascade(),
            pids: [99],
            visibleRect: standardRect,
            currentFrames: [:]
        )
        XCTAssertEqual(plan[99]!.size, CGSize(width: 1024, height: 768))
    }

    func testCascade_WrapsToNewColumnWhenStackExceedsHeight() {
        // 800-tall visible rect, 60px title-bar headroom. With offsetY=40,
        // a stack of 19 windows pushes past the bottom and wraps. The
        // 20th lands in a new column starting 200px right.
        let current = (1...20).reduce(into: [pid_t: CGRect]()) { dict, n in
            dict[pid_t(n)] = CGRect(x: 0, y: 0, width: 800, height: 600)
        }
        let pids = (1...20).map(pid_t.init)
        let plan = WindowLayoutPlanner.plan(
            mode: .cascade(),
            pids: pids,
            visibleRect: standardRect,
            currentFrames: current
        )
        // First window at origin.
        XCTAssertEqual(plan[1]!.origin, .zero)
        // At least one window should have wrapped into a new column —
        // x > 0 + offsetX*N for some N. Detect by finding any window
        // whose x is at the wrap-column base (200) and y back near 0.
        let wrapped = plan.values.contains {
            abs($0.origin.x - 200) < 5 && $0.origin.y < 60
        }
        XCTAssertTrue(wrapped, "Cascade should wrap to a new column when the stack exceeds visibleRect height")
    }
}
