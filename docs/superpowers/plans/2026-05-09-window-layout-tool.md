# Window Layout Tool — Implementation Plan (P1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the P1 toolbar-driven Window Layout Tool — Tile submenu (5 modes) operating on RORORO-tracked Roblox windows via Accessibility API.

**Architecture:** Pure-value layout planner (testable without AppKit), protocol-fronted AX manager (testable with stubs), `@Observable` view model bridging UI taps to manager calls, single Menu toolbar item slotted between Multi-instance and Cycler. Reuses existing Accessibility TCC bucket — no new permission ask.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, ApplicationServices (AX API), XCTest, XcodeGen.

**Spec:** [`docs/superpowers/specs/2026-05-09-window-layout-tool-design.md`](../specs/2026-05-09-window-layout-tool-design.md)
**ADR:** [`docs/decisions/0005-window-layout-tool.md`](../../decisions/0005-window-layout-tool.md)

---

## File Structure

| Path | New / Modify | Responsibility |
|---|---|---|
| `App/RORORO/Domain/WindowLayout/LayoutMode.swift` | New | Enum: `.grid(cols, rows)`, `.autoGrid`, `.shrink(percent)`. |
| `App/RORORO/Domain/WindowLayout/WindowLayoutPlanner.swift` | New | Pure value type. `static plan(...)` computes target frames. No AppKit. |
| `App/RORORO/Domain/WindowLayout/AXWindowManager.swift` | New | Protocol + `DefaultAXWindowManager`. AX wrappers for `kAXPosition` + `kAXSize`. |
| `App/RORORO/UI/WindowLayoutViewModel.swift` | New | `@MainActor @Observable` singleton bridging UI to domain. |
| `App/RORORO/UI/WindowLayoutToolbarView.swift` | New | Toolbar Menu button. Tile submenu enabled; Shrink/Custom disabled. |
| `App/RORORO/UI/ContentView.swift` | Modify | One-line insert in `ToolbarItemGroup`. |
| `App/ROROROTests/WindowLayoutPlannerTests.swift` | New | XCTest cases for grid/shrink math. |

> **Note:** test file lives flat in `App/ROROROTests/` per existing project convention (the spec said `Tests/RORORO/Domain/...` — that was the abstract intent; concrete path follows the repo's actual test target layout).

**XcodeGen note:** `App/project.yml` uses `sources: - path: RORORO` (recursive), so adding files under `App/RORORO/Domain/WindowLayout/` is auto-picked up after `xcodegen generate`. No `project.yml` edit needed.

**Build/test commands** (verified against `CLAUDE.md`):

- Generate Xcode project: `cd App && xcodegen generate`
- Build: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO build`
- Test: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64'`

---

## Task 1: LayoutMode enum

**Files:**
- Create: `App/RORORO/Domain/WindowLayout/LayoutMode.swift`

- [ ] **Step 1: Create the enum**

```swift
// LayoutMode.swift
// Domain — what the WindowLayoutPlanner is being asked to compute.
// Three shapes: explicit grid (cols × rows specified), auto-grid
// (ceil(sqrt(N)) packing), and shrink (per-window center-anchored
// proportional resize). See ADR 0005 Decisions 4 + 5.

import Foundation

public enum LayoutMode: Equatable, Sendable {
    /// Explicit grid. cols × rows cells; row-major fill from top-left.
    case grid(cols: Int, rows: Int)

    /// Automatic ceil(sqrt(N)) packing. Planner computes cols/rows
    /// from the window count.
    case autoGrid

    /// Per-window center-anchored shrink. `percent` is 0.0–1.0
    /// (0.5 = half size). Each window stays centered on its current
    /// center; only width × height change.
    case shrink(percent: Double)
}
```

- [ ] **Step 2: Commit**

```bash
git add App/RORORO/Domain/WindowLayout/LayoutMode.swift
git commit -m "feat(window-layout): LayoutMode enum (Slope D wave 1)"
```

---

## Task 2: WindowLayoutPlanner — auto-grid math (TDD)

**Files:**
- Create: `App/RORORO/Domain/WindowLayout/WindowLayoutPlanner.swift`
- Create: `App/ROROROTests/WindowLayoutPlannerTests.swift`

- [ ] **Step 1: Write the failing test for N=4 → 2×2**

Create `App/ROROROTests/WindowLayoutPlannerTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run test to verify it fails (no planner yet)**

```bash
cd App && xcodegen generate && cd ..
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
  -destination 'platform=macOS,arch=x86_64' \
  -only-testing:ROROROTests/WindowLayoutPlannerTests 2>&1 | tail -20
```

Expected: BUILD FAIL — `cannot find 'WindowLayoutPlanner' in scope`.

- [ ] **Step 3: Create the planner with minimal autoGrid implementation**

Create `App/RORORO/Domain/WindowLayout/WindowLayoutPlanner.swift`:

```swift
// WindowLayoutPlanner.swift
// Domain — pure value type. Computes target CGRect frames for a set of
// pids given a LayoutMode, a visible-rect (NSScreen.visibleFrame),
// and the windows' current frames. No I/O, no AppKit dependency —
// fully unit-testable. See ADR 0005 Decisions 4 + 5 for math.

import CoreGraphics
import Foundation

public struct WindowLayoutPlanner {

    public static func plan(
        mode: LayoutMode,
        pids: [pid_t],
        visibleRect: CGRect,
        currentFrames: [pid_t: CGRect]
    ) -> [pid_t: CGRect] {
        guard !pids.isEmpty else { return [:] }
        let sorted = pids.sorted()  // stable ordering by pid

        switch mode {
        case .autoGrid:
            let n = sorted.count
            let cols = Int(ceil(Double(n).squareRoot()))
            let rows = Int(ceil(Double(n) / Double(cols)))
            return gridFrames(pids: sorted, cols: cols, rows: rows, in: visibleRect)

        case .grid(let cols, let rows):
            return gridFrames(pids: sorted, cols: cols, rows: rows, in: visibleRect)

        case .shrink(let percent):
            return shrinkFrames(pids: sorted, percent: percent, currentFrames: currentFrames)
        }
    }

    // MARK: - private

    private static func gridFrames(
        pids: [pid_t],
        cols: Int,
        rows: Int,
        in rect: CGRect
    ) -> [pid_t: CGRect] {
        guard cols > 0, rows > 0 else { return [:] }
        let cellW = rect.width  / CGFloat(cols)
        let cellH = rect.height / CGFloat(rows)
        var out: [pid_t: CGRect] = [:]
        for (i, pid) in pids.enumerated() {
            let row = i / cols
            let col = i % cols
            guard row < rows else { break }  // overflow → drop
            out[pid] = CGRect(
                x: rect.origin.x + CGFloat(col) * cellW,
                y: rect.origin.y + CGFloat(row) * cellH,
                width: cellW,
                height: cellH
            )
        }
        return out
    }

    private static func shrinkFrames(
        pids: [pid_t],
        percent: Double,
        currentFrames: [pid_t: CGRect]
    ) -> [pid_t: CGRect] {
        var out: [pid_t: CGRect] = [:]
        for pid in pids {
            guard let current = currentFrames[pid] else { continue }
            let newW = current.width  * CGFloat(percent)
            let newH = current.height * CGFloat(percent)
            let centerX = current.midX
            let centerY = current.midY
            out[pid] = CGRect(
                x: centerX - newW / 2,
                y: centerY - newH / 2,
                width: newW,
                height: newH
            )
        }
        return out
    }
}
```

- [ ] **Step 4: Run test, expect PASS**

```bash
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
  -destination 'platform=macOS,arch=x86_64' \
  -only-testing:ROROROTests/WindowLayoutPlannerTests/testAutoGrid_N4_Yields2x2 2>&1 | tail -20
```

Expected: `Test Case '-[ROROROTests.WindowLayoutPlannerTests testAutoGrid_N4_Yields2x2]' passed`.

- [ ] **Step 5: Add the rest of the autoGrid test matrix**

Append to `WindowLayoutPlannerTests.swift`:

```swift
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
```

- [ ] **Step 6: Run all autoGrid tests, expect PASS**

```bash
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
  -destination 'platform=macOS,arch=x86_64' \
  -only-testing:ROROROTests/WindowLayoutPlannerTests 2>&1 | tail -30
```

Expected: 7 autoGrid tests pass.

- [ ] **Step 7: Commit**

```bash
git add App/RORORO/Domain/WindowLayout/WindowLayoutPlanner.swift \
        App/ROROROTests/WindowLayoutPlannerTests.swift
git commit -m "feat(window-layout): planner auto-grid math + tests"
```

---

## Task 3: Planner — explicit grid mode

**Files:**
- Modify: `App/ROROROTests/WindowLayoutPlannerTests.swift` (add cases — implementation already covers `.grid` via `gridFrames`)

- [ ] **Step 1: Write tests for explicit `.grid` mode**

Append to `WindowLayoutPlannerTests.swift`:

```swift
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
```

- [ ] **Step 2: Run grid tests, expect PASS**

```bash
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
  -destination 'platform=macOS,arch=x86_64' \
  -only-testing:ROROROTests/WindowLayoutPlannerTests 2>&1 | tail -30
```

Expected: 5 new explicit-grid tests pass; total 12 passing.

- [ ] **Step 3: Commit**

```bash
git add App/ROROROTests/WindowLayoutPlannerTests.swift
git commit -m "test(window-layout): explicit grid + stable-sort coverage"
```

---

## Task 4: Planner — shrink mode

**Files:**
- Modify: `App/ROROROTests/WindowLayoutPlannerTests.swift` (add cases — `shrinkFrames` already implemented in Task 2)

- [ ] **Step 1: Write shrink tests**

Append to `WindowLayoutPlannerTests.swift`:

```swift
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
```

- [ ] **Step 2: Run shrink tests, expect PASS**

```bash
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
  -destination 'platform=macOS,arch=x86_64' \
  -only-testing:ROROROTests/WindowLayoutPlannerTests 2>&1 | tail -30
```

Expected: 5 new shrink tests pass; total 17 passing.

- [ ] **Step 3: Commit**

```bash
git add App/ROROROTests/WindowLayoutPlannerTests.swift
git commit -m "test(window-layout): center-anchored shrink coverage"
```

---

## Task 5: AXWindowManager — protocol + default impl

**Files:**
- Create: `App/RORORO/Domain/WindowLayout/AXWindowManager.swift`

> **Note:** AX calls hit the live system; unit-testing real moves requires a running window. We test the planner exhaustively (covered above) and verify AXWindowManager via manual acceptance (Task 9). The protocol is shaped so a future test double can stub `resize` calls without AX.

- [ ] **Step 1: Create the protocol + concrete impl**

```swift
// AXWindowManager.swift
// Domain — DI seam for AX window-attribute reads/writes (Slope D wave 1,
// ADR 0005). Wraps `AXUIElementSetAttributeValue` against `kAXPosition`
// + `kAXSize` so the layout view-model never touches ApplicationServices
// directly. Mirrors the `WindowFocuser` protocol shape from Slope C.
//
// Reuses the existing Accessibility TCC bucket — no new permission ask.
// If TCC is missing the AX calls return `.cannotComplete`; callers route
// through `AutoKeysPermissions.openAccessibilitySettings()` (same as the
// cycler's preflight).

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public protocol AXWindowManager: Sendable {
    /// Read the current frame of the app's main window.
    func mainWindowFrame(pid: pid_t) async throws -> CGRect

    /// Move + resize the app's main window. The two attribute writes are
    /// distinct AX calls; either may fail independently. We attempt both
    /// and only throw if BOTH fail (one-of-two success is still useful).
    func resize(pid: pid_t, to frame: CGRect) async throws
}

public enum AXWindowManagerError: Error, Equatable {
    case notRunning(pid: pid_t)
    case noMainWindow(pid: pid_t)
    case axCallFailed(code: Int32)
}

public struct DefaultAXWindowManager: AXWindowManager {

    public init() {}

    public func mainWindowFrame(pid: pid_t) async throws -> CGRect {
        guard NSRunningApplication(processIdentifier: pid) != nil else {
            throw AXWindowManagerError.notRunning(pid: pid)
        }
        let app = AXUIElementCreateApplication(pid)
        let window = try copyMainWindow(of: app, pid: pid)

        var posValue: AnyObject?
        var sizeValue: AnyObject?
        let posErr = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue)
        let sizeErr = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
        guard posErr == .success, sizeErr == .success,
              let pos = posValue, let size = sizeValue else {
            throw AXWindowManagerError.axCallFailed(code: max(posErr.rawValue, sizeErr.rawValue))
        }
        var origin = CGPoint.zero
        var dim = CGSize.zero
        // AXValueGetValue copies the underlying point/size out of the AXValue wrapper.
        AXValueGetValue(pos as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &dim)
        return CGRect(origin: origin, size: dim)
    }

    public func resize(pid: pid_t, to frame: CGRect) async throws {
        guard NSRunningApplication(processIdentifier: pid) != nil else {
            throw AXWindowManagerError.notRunning(pid: pid)
        }
        let app = AXUIElementCreateApplication(pid)
        let window = try copyMainWindow(of: app, pid: pid)

        var origin = frame.origin
        var size = frame.size
        // AXValueCreate wraps point/size into the AXValue type the AX
        // attribute setter expects. Force-unwrap is safe — both
        // .cgPoint / .cgSize are documented-supported variants.
        let posValue = AXValueCreate(.cgPoint, &origin)!
        let sizeValue = AXValueCreate(.cgSize, &size)!

        let posErr = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        let sizeErr = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)

        // One-of-two success is acceptable (some Roblox windows resist
        // size-set during early load but accept position-set, and vice
        // versa). Throw only if BOTH failed.
        if posErr != .success && sizeErr != .success {
            NSLog("[RORORO] layout: pid=\(pid) resize failed pos=\(posErr.rawValue) size=\(sizeErr.rawValue)")
            throw AXWindowManagerError.axCallFailed(code: max(posErr.rawValue, sizeErr.rawValue))
        }
    }

    // MARK: - private

    private func copyMainWindow(of app: AXUIElement, pid: pid_t) throws -> AXUIElement {
        var window: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            app, kAXMainWindowAttribute as CFString, &window
        )
        guard err == .success, let w = window else {
            if err == .cannotComplete || err == .apiDisabled {
                throw AXWindowManagerError.axCallFailed(code: err.rawValue)
            }
            throw AXWindowManagerError.noMainWindow(pid: pid)
        }
        // Force-cast is safe — kAXMainWindowAttribute returns AXUIElement
        // per Apple docs (matches WindowFocuser.swift pattern).
        return w as! AXUIElement
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
cd App && xcodegen generate && cd ..
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/RORORO/Domain/WindowLayout/AXWindowManager.swift
git commit -m "feat(window-layout): AXWindowManager protocol + default impl"
```

---

## Task 6: WindowLayoutViewModel

**Files:**
- Create: `App/RORORO/UI/WindowLayoutViewModel.swift`

- [ ] **Step 1: Create the view model**

```swift
// WindowLayoutViewModel.swift
// UI-glue — bridges the toolbar Menu taps to the domain layer
// (WindowLayoutPlanner + AXWindowManager). Singleton, MainActor,
// @Observable so SwiftUI re-renders on `lastError` changes.
//
// Reads pids from RunningAccountTracker.shared. Reads cycler state
// from AutoKeysCyclerViewModel.shared so menu items can disable while
// the cycler is .running (ADR 0005 Decision 3).

import AppKit
import Foundation
import Observation

@MainActor
@Observable
public final class WindowLayoutViewModel {

    public static let shared = WindowLayoutViewModel(manager: DefaultAXWindowManager())

    private let manager: AXWindowManager

    /// Set when an apply call hits an unrecoverable error (TCC missing,
    /// or both AX writes failed for every window). Toolbar surfaces via
    /// .alert. Per-window failures DO NOT set this — they log + skip.
    public var lastError: String? = nil

    public init(manager: AXWindowManager) {
        self.manager = manager
    }

    public func clearError() {
        lastError = nil
    }

    // MARK: - public actions

    public func applyAutoGrid() async {
        await apply(mode: .autoGrid)
    }

    public func applyGrid(cols: Int, rows: Int) async {
        await apply(mode: .grid(cols: cols, rows: rows))
    }

    public func applyShrink(percent: Double) async {
        await apply(mode: .shrink(percent: percent))
    }

    // MARK: - private

    private func apply(mode: LayoutMode) async {
        // Defense-in-depth: UI also disables the menu items, but if the
        // VM is invoked some other way we still bail.
        if case .running = AutoKeysCyclerViewModel.shared.state {
            lastError = "Stop auto-keys before rearranging windows."
            return
        }

        let pids = Array(RunningAccountTracker.shared.pidsByUserId.values)
        guard !pids.isEmpty else {
            lastError = "No RORORO-launched Roblox windows are running."
            return
        }

        let visibleRect = currentVisibleRect()

        // Read current frames only when needed (shrink). For grid modes
        // we don't need them — saves one AX round-trip per pid.
        var currentFrames: [pid_t: CGRect] = [:]
        if case .shrink = mode {
            for pid in pids {
                if let frame = try? await manager.mainWindowFrame(pid: pid) {
                    currentFrames[pid] = frame
                }
            }
        }

        let plan = WindowLayoutPlanner.plan(
            mode: mode,
            pids: pids,
            visibleRect: visibleRect,
            currentFrames: currentFrames
        )

        var anySucceeded = false
        for (pid, frame) in plan {
            do {
                try await manager.resize(pid: pid, to: frame)
                anySucceeded = true
            } catch {
                NSLog("[RORORO] layout: pid=\(pid) resize threw \(error)")
                // Continue — per-window failures are fail-soft.
            }
        }

        if !anySucceeded {
            lastError = "No windows were rearranged. Accessibility permission may be missing — open System Settings → Privacy & Security → Accessibility and grant RORORO."
        }
    }

    private func currentVisibleRect() -> CGRect {
        if let screen = NSApp.mainWindow?.screen {
            return screen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? .zero
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
cd App && xcodegen generate && cd ..
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/RORORO/UI/WindowLayoutViewModel.swift
git commit -m "feat(window-layout): view model — pids + planner + AX glue"
```

---

## Task 7: WindowLayoutToolbarView

**Files:**
- Create: `App/RORORO/UI/WindowLayoutToolbarView.swift`

- [ ] **Step 1: Create the toolbar Menu view**

```swift
// WindowLayoutToolbarView.swift
// UI — toolbar Menu for the Window Layout Tool (Slope D wave 1,
// ADR 0005). Sits between the Multi-instance toggle and the Cycler in
// `ContentView`. Tile submenu enabled in P1; Shrink + Custom items
// present but disabled (P2).
//
// Cycler-state reactive disable: while AutoKeysCyclerViewModel.shared
// is .running, every action item is disabled with a tooltip pointing
// at the cycler's Stop button.

import SwiftUI

struct WindowLayoutToolbarView: View {

    @State private var vm = WindowLayoutViewModel.shared
    @State private var cyclerVM = AutoKeysCyclerViewModel.shared

    var body: some View {
        Menu {
            tileSection
            Divider()
            shrinkSection
            Divider()
            Button("Custom Size…") { /* P2 */ }
                .disabled(true)
                .help("Coming soon — custom size slider lands in P2.")
        } label: {
            Label("Layout", systemImage: "rectangle.3.offgrid")
                .foregroundStyle(Theme.Color.fg2)
        }
        .menuStyle(.borderlessButton)
        .help(menuHelp)
        .alert(
            "Window Layout",
            isPresented: Binding(
                get: { vm.lastError != nil },
                set: { newValue in if !newValue { vm.clearError() } }
            )
        ) {
            if let msg = vm.lastError, msg.contains("Accessibility") {
                Button("Open Settings") {
                    AutoKeysPermissions.openAccessibilitySettings()
                    vm.clearError()
                }
            }
            Button("OK") { vm.clearError() }
        } message: {
            Text(vm.lastError ?? "")
        }
    }

    // MARK: - sections

    @ViewBuilder
    private var tileSection: some View {
        Menu("Tile") {
            Button("Auto-grid") {
                Task { await vm.applyAutoGrid() }
            }
            .disabled(cyclerIsRunning)
            Divider()
            Button("2 × 2") {
                Task { await vm.applyGrid(cols: 2, rows: 2) }
            }
            .disabled(cyclerIsRunning)
            Button("3 × 3") {
                Task { await vm.applyGrid(cols: 3, rows: 3) }
            }
            .disabled(cyclerIsRunning)
            Divider()
            Button("Row (1 × N)") {
                Task {
                    let n = max(1, RunningAccountTracker.shared.pidsByUserId.count)
                    await vm.applyGrid(cols: n, rows: 1)
                }
            }
            .disabled(cyclerIsRunning)
            Button("Column (N × 1)") {
                Task {
                    let n = max(1, RunningAccountTracker.shared.pidsByUserId.count)
                    await vm.applyGrid(cols: 1, rows: n)
                }
            }
            .disabled(cyclerIsRunning)
        }
    }

    @ViewBuilder
    private var shrinkSection: some View {
        Menu("Shrink") {
            Button("25%") { /* P2 */ }.disabled(true)
            Button("50%") { /* P2 */ }.disabled(true)
            Button("75%") { /* P2 */ }.disabled(true)
            Button("100% (restore)") { /* P2 */ }.disabled(true)
        }
        .help("Coming soon — shrink presets land in P2.")
    }

    // MARK: - state

    private var cyclerIsRunning: Bool {
        if case .running = cyclerVM.state { return true }
        return false
    }

    private var menuHelp: String {
        cyclerIsRunning
            ? "Stop auto-keys to rearrange windows."
            : "Tile or resize all running Roblox windows."
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/RORORO/UI/WindowLayoutToolbarView.swift
git commit -m "feat(window-layout): toolbar Menu — Tile submenu + disabled P2 stubs"
```

---

## Task 8: ContentView wire-in

**Files:**
- Modify: `App/RORORO/UI/ContentView.swift` (one insertion in `ToolbarItemGroup`)

- [ ] **Step 1: Insert WindowLayoutToolbarView between multiInstanceToggle and CyclerToolbarView**

Open `App/RORORO/UI/ContentView.swift`. Find:

```swift
                ToolbarItemGroup(placement: .primaryAction) {
                    multiInstanceToggle
                    CyclerToolbarView()
```

Replace with:

```swift
                ToolbarItemGroup(placement: .primaryAction) {
                    multiInstanceToggle
                    WindowLayoutToolbarView()
                    CyclerToolbarView()
```

- [ ] **Step 2: Build to verify it compiles**

```bash
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the full test suite to verify no regressions**

```bash
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
  -destination 'platform=macOS,arch=x86_64' 2>&1 | tail -10
```

Expected: all existing tests pass; 17 new `WindowLayoutPlannerTests` cases pass.

- [ ] **Step 4: Commit**

```bash
git add App/RORORO/UI/ContentView.swift
git commit -m "feat(window-layout): wire toolbar button into ContentView"
```

---

## Task 9: Manual acceptance pass

> **No code in this task — pure verification. The commits above ship the feature; this task is the gate before declaring P1 done.**

- [ ] **Step 1: Launch the app from Xcode**

```bash
xed App/RORORO.xcodeproj
# In Xcode: Cmd+R
```

- [ ] **Step 2: Verify toolbar layout**

The toolbar should show, left → right:

`[Multi-instance toggle] [Layout (rectangle.3.offgrid)] [Cycler] [Games] [Settings] [More]`

If Layout button is missing or in the wrong slot → revisit Task 8.

- [ ] **Step 3: Verify menu structure with no Roblox windows**

Click Layout. Verify:
- "Tile" submenu opens, all 5 items visible (Auto-grid / 2×2 / 3×3 / Row / Column).
- "Shrink" submenu shows 4 items, all disabled with "Coming soon" tooltip.
- "Custom Size…" disabled with "Coming soon" tooltip.
- Tile items enabled (they'll error gracefully when clicked with no running windows).

Click "Tile → Auto-grid" with no Roblox windows. Verify alert appears: "No RORORO-launched Roblox windows are running." Dismiss.

- [ ] **Step 4: Launch 4 Roblox accounts and tile**

In RORORO: enable Multi-instance, launch 4 accounts. Wait for all 4 Roblox windows to be visible (may take 10–15 s).

Click Layout → Tile → Auto-grid.

Expected: all 4 Roblox windows snap into a 2×2 grid filling the active screen. Window positions stable across re-clicks (sorted by pid).

- [ ] **Step 5: Verify other grid modes**

Click Tile → 3 × 3. Expected: 4 windows fill the top row + first column of a 3×3 grid (cells 0–3 in row-major order).

Click Tile → Row. Expected: 4 windows in a single row, each 1/4 screen wide.

Click Tile → Column. Expected: 4 windows stacked vertically, each 1/4 screen tall.

Click Tile → Auto-grid. Expected: back to 2×2.

- [ ] **Step 6: Verify cycler-state gating**

Configure auto-keys for at least 2 accounts (per existing AutoKeys flow). Click the cycler's Play button.

While cycler is `.running`, open the Layout menu. Verify all 5 Tile items are **disabled**. Hover over the menu — tooltip reads "Stop auto-keys to rearrange windows."

Click cycler's Stop. Re-open Layout menu. Verify Tile items are re-enabled.

- [ ] **Step 7: Verify multi-display behavior (if available)**

Drag RORORO's main window to a secondary display. Click Layout → Tile → Auto-grid. Verify windows tile on the secondary display, not the primary.

- [ ] **Step 8: Verify TCC re-prompt path (optional but recommended)**

System Settings → Privacy & Security → Accessibility → toggle RORORO **off**. Restart the app. Click Tile → Auto-grid.

Expected: alert appears with "Open Settings" button. Click → System Settings opens to Accessibility pane. Re-grant. Re-launch. Tile works.

- [ ] **Step 9: Mark P1 complete**

If all steps above pass:

```bash
git log --oneline -8
```

Expect 8 commits since `1f37aec` (the lint commit before this plan):

1. `feat(window-layout): LayoutMode enum (Slope D wave 1)`
2. `feat(window-layout): planner auto-grid math + tests`
3. `test(window-layout): explicit grid + stable-sort coverage`
4. `test(window-layout): center-anchored shrink coverage`
5. `feat(window-layout): AXWindowManager protocol + default impl`
6. `feat(window-layout): view model — pids + planner + AX glue`
7. `feat(window-layout): toolbar Menu — Tile submenu + disabled P2 stubs`
8. `feat(window-layout): wire toolbar button into ContentView`

P1 ships with these 8 commits. P2 (Shrink + Custom) is additive on this plumbing — see ADR 0005 phasing table.

- [ ] **Step 10: Log a 626 dashboard decision (optional, post-merge)**

Per the project's CLAUDE.md, log a decision via `mcp__626Labs__manage_decisions log`:

- **Title:** Window Layout Tool ships P1 (tile-only)
- **Body:** Reused Accessibility TCC bucket — no new permission ask. AXWindowManager pattern ports straight from WindowFocuser. Phasing posture: P1 valuable alone; P2 (shrink + custom) additive on same plumbing.

---

## Self-Review

**Spec coverage check:** Each spec section maps to ≥1 task —
- Spec §4.1 (component map) → Tasks 1, 2, 5, 6, 7
- Spec §4.2 (separation rationale) → reflected in file structure section
- Spec §5.1–5.3 (data flow) → Tasks 6, 7
- Spec §6 (error handling) → Task 6 step 1 (lastError surface, per-window fail-soft)
- Spec §7.1 (unit tests) → Tasks 2, 3, 4
- Spec §7.2 (manual acceptance) → Task 9
- Spec §8 (phased delivery — P1 scope) → all tasks; P2/P3 explicitly out

**Placeholder scan:** No "TBD", "TODO", "implement later" in any step. P2 stubs in toolbar are explicit placeholder buttons by design — disabled with "Coming soon" tooltip per ADR Decision; not plan-failure placeholders.

**Type consistency:** `LayoutMode.shrink(percent: Double)` used consistently across enum, planner, VM. `pid_t` used everywhere (no mixing with `Int32`). `CGRect` returned by planner + AX manager throughout. `applyGrid(cols:rows:)` / `applyAutoGrid()` / `applyShrink(percent:)` signatures match between VM and toolbar callers.

**Build commands:** `xcodebuild ... -destination 'platform=macOS,arch=x86_64'` consistent across all test steps; `cd App && xcodegen generate && cd ..` before first compile to ensure new files are picked up.

No issues found. Plan is consistent with the spec.
