<!-- Every item uses the five-field format. /build reads each item and
     relies on all five fields being present and consistently formatted.
     The header encodes methodology choices so /build doesn't re-ask. -->

# Build Checklist — Window Layout Tool (P1)

> **Scope note for `/build`:** This is a *feature* build atop an already-shipped product. The product-level `docs/spec.md` and `docs/prd.md` are background context only — the load-bearing artifact for THIS build is the feature spec at [`docs/superpowers/specs/2026-05-09-window-layout-tool-design.md`](superpowers/specs/2026-05-09-window-layout-tool-design.md) and ADR [`docs/decisions/0005-window-layout-tool.md`](decisions/0005-window-layout-tool.md). When dispatching subagents, pass the feature spec — not the product spec — as the architectural context.
>
> Documentation & security review for the product as a whole was completed previously; this checklist's final item (manual acceptance) is the feature's verification gate, not a project-wide doc/security pass.

## Build Preferences

- **Build mode:** Autonomous
- **Comprehension checks:** N/A (autonomous mode)
- **Git:** Commit after each item with conventional-commit style. Subject pattern: `feat(window-layout): [item title]` for production code; `test(window-layout): [item title]` for test-only items. Co-author trailer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.
- **Verification:** Yes — checkpoint every 3-4 items. Build → orchestrator runs xcodebuild, reports result. Final manual acceptance is its own item.
- **Check-in cadence:** N/A (autonomous)

## Checklist

- [x] **1. LayoutMode enum**
  Spec ref: `superpowers/specs/2026-05-09-window-layout-tool-design.md > §4.1 Component map > Domain Layer`
  What to build: Create `App/RORORO/Domain/WindowLayout/LayoutMode.swift` exposing a public `LayoutMode: Equatable, Sendable` enum with three cases: `.grid(cols: Int, rows: Int)`, `.autoGrid`, `.shrink(percent: Double)`. Doc-comment each case explaining its semantic. Full code body is in the implementation plan task 1 step 1 (`docs/superpowers/plans/2026-05-09-window-layout-tool.md`).
  Acceptance: File exists, project compiles after `cd App && xcodegen generate && xcodebuild -project App/RORORO.xcodeproj -scheme RORORO build`.
  Verify: Run `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO build 2>&1 | tail -5`. Expect `** BUILD SUCCEEDED **`.

- [x] **2. WindowLayoutPlanner — auto-grid math (TDD)**
  Spec ref: `superpowers/specs/2026-05-09-window-layout-tool-design.md > §4.1 Component map > WindowLayoutPlanner` and `decisions/0005-window-layout-tool.md > Decision 4 — Auto-grid algorithm`.
  What to build: Create `App/RORORO/Domain/WindowLayout/WindowLayoutPlanner.swift` (pure value type, no AppKit) with `static func plan(mode:pids:visibleRect:currentFrames:) -> [pid_t: CGRect]`. Implement `.autoGrid` and `.grid(cols:rows:)` via row-major fill with `ceil(sqrt(N))` packing. Stub `.shrink` (added in item 4). Create `App/ROROROTests/WindowLayoutPlannerTests.swift` and write the 7 auto-grid tests (N=1, 2, 3, 4, 5, 9, empty, plus visible-rect-origin). Full code in implementation plan task 2.
  Acceptance: All 7 auto-grid tests pass. Stable userId-sorted ordering (running same plan twice yields identical output). N=0 yields empty plan.
  Verify: Run `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -only-testing:ROROROTests/WindowLayoutPlannerTests 2>&1 | tail -10`. Expect 7 tests passed, 0 failed.

- [x] **3. WindowLayoutPlanner — explicit grid tests**
  Spec ref: `superpowers/specs/2026-05-09-window-layout-tool-design.md > §7.1 Unit tests > Explicit grid`.
  What to build: Append 5 explicit-grid tests to `App/ROROROTests/WindowLayoutPlannerTests.swift`: 3×3 with N=5 fills row-major, 1×N row stretches across, N×1 column stacks vertically, 2×2 with N=5 drops the overflow pid, stable-sort determinism. The implementation already covers `.grid` from item 2 — this item is test-only. Full test bodies in implementation plan task 3.
  Acceptance: All 5 explicit-grid tests pass; 12 total planner tests passing.
  Verify: Run `xcodebuild ... test -only-testing:ROROROTests/WindowLayoutPlannerTests 2>&1 | tail -10`. Expect 12 tests passed.

- [x] **4. WindowLayoutPlanner — shrink mode + tests**
  Spec ref: `decisions/0005-window-layout-tool.md > Decision 5 — Shrink anchor` and `superpowers/specs/2026-05-09-window-layout-tool-design.md > §7.1 Unit tests > Shrink`.
  What to build: Implement `.shrink(percent:)` in `WindowLayoutPlanner` — anchor on each window's current center, scale width × height by `percent`. Append 5 shrink tests: 50% preserves center (table-driven exact CGRect assertion), 25% quarter-size, 100% no-op, pid without current frame is dropped, multiple windows each preserve own center. Full code in implementation plan task 4.
  Acceptance: All 5 shrink tests pass; 17 total planner tests passing. Center-anchored math verified against the canonical example (200,100,1280,720) → 50% → (520,280,640,360).
  Verify: Run `xcodebuild ... test -only-testing:ROROROTests/WindowLayoutPlannerTests 2>&1 | tail -10`. Expect 17 tests passed.

- [x] **5. AXWindowManager — protocol + DefaultAXWindowManager**
  Spec ref: `superpowers/specs/2026-05-09-window-layout-tool-design.md > §4.1 Component map > AXWindowManager` and `decisions/0005-window-layout-tool.md > Implementation map > Domain — service`.
  What to build: Create `App/RORORO/Domain/WindowLayout/AXWindowManager.swift` exposing `AXWindowManager: Sendable` protocol with `mainWindowFrame(pid:) async throws -> CGRect` and `resize(pid:to:) async throws`, plus `AXWindowManagerError` enum (`.notRunning`, `.noMainWindow`, `.axCallFailed`). Concrete `DefaultAXWindowManager` wraps `AXUIElementSetAttributeValue` for `kAXPositionAttribute` + `kAXSizeAttribute` using `AXValueCreate(.cgPoint)` / `AXValueCreate(.cgSize)`. Mirrors the proven `WindowFocuser` pattern (Slope C wave 1). Full code in implementation plan task 5.
  Acceptance: Protocol + impl compile clean. NSLog line on resize failure includes both pos/size error codes. One-of-two success treated as success (e.g., position-set succeeds even if size-set fails).
  Verify: Run `cd App && xcodegen generate && cd .. && xcodebuild -project App/RORORO.xcodeproj -scheme RORORO build 2>&1 | tail -5`. Expect `** BUILD SUCCEEDED **`.

- [x] **6. WindowLayoutViewModel**
  Spec ref: `superpowers/specs/2026-05-09-window-layout-tool-design.md > §4.1 Component map > WindowLayoutViewModel` and §5 Data flow §6 Error handling.
  What to build: Create `App/RORORO/UI/WindowLayoutViewModel.swift` — `@MainActor @Observable` singleton with `applyAutoGrid()`, `applyGrid(cols:rows:)`, `applyShrink(percent:)` async methods. Reads pids from `RunningAccountTracker.shared`, current frames from `AXWindowManager` (only when needed for shrink), visible rect from `NSApp.mainWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame`. Cycler-state guard at the start of `apply(mode:)` (defense-in-depth — the UI also disables menu items). Per-window failures fail-soft (log + continue); whole-batch failure surfaces via `lastError` for an alert. Full code in implementation plan task 6.
  Acceptance: VM compiles. Cycler-state guard returns early with user-facing error when `AutoKeysCyclerViewModel.shared.state == .running`. Empty pids set returns early with "No RORORO-launched Roblox windows are running."
  Verify: Run `xcodebuild ... build 2>&1 | tail -5`. Expect `** BUILD SUCCEEDED **`.

- [x] **7. WindowLayoutToolbarView**
  Spec ref: `superpowers/specs/2026-05-09-window-layout-tool-design.md > §4.1 Component map > WindowLayoutToolbarView` and `decisions/0005-window-layout-tool.md > §3 Decision (placement and shape, implicit in Implementation map)`.
  What to build: Create `App/RORORO/UI/WindowLayoutToolbarView.swift` — SwiftUI `Menu` with `Label("Layout", systemImage: "rectangle.3.offgrid")`. Tile submenu enabled with 5 items (Auto-grid / 2×2 / 3×3 / Row (1×N) / Column (N×1)) — Row/Column compute N from `RunningAccountTracker.shared.pidsByUserId.count`. Shrink submenu present with 4 items, all `.disabled(true)` and "Coming soon" tooltip (P2 placeholders). "Custom Size…" item also disabled. Cycler-state reactive disable on every Tile button via `cyclerIsRunning` computed property reading `AutoKeysCyclerViewModel.shared.state`. Alert binding wired to `vm.lastError` with "Open Settings" action when error mentions "Accessibility". Use `Theme.Color.fg2` for the label foreground. Full code in implementation plan task 7.
  Acceptance: View compiles. Tile items disabled when cycler is `.running`; enabled otherwise. Shrink + Custom items disabled with helpful tooltips. Alert presents `vm.lastError` and clears it on dismiss.
  Verify: Run `xcodebuild ... build 2>&1 | tail -5`. Expect `** BUILD SUCCEEDED **`.

- [x] **8. ContentView wire-in**
  Spec ref: `decisions/0005-window-layout-tool.md > Implementation map > UI — wiring`.
  What to build: Modify `App/RORORO/UI/ContentView.swift` — insert `WindowLayoutToolbarView()` into the `ToolbarItemGroup(placement: .primaryAction)` between `multiInstanceToggle` and `CyclerToolbarView()`. One-line insert. After this item the toolbar reads (left → right): Multi-instance toggle · Layout · Cycler · Games · Settings · More.
  Acceptance: Toolbar order matches the spec's component map. Full test suite passes (no regressions in existing tests).
  Verify: Run `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' 2>&1 | tail -10`. Expect all existing tests + 17 planner tests passing.

- [ ] **9. Manual acceptance + dashboard decision log**
  Spec ref: `superpowers/specs/2026-05-09-window-layout-tool-design.md > §7.2 Integration / manual (P1 acceptance)` (steps 1–7) and `decisions/0005-window-layout-tool.md > Phasing > Phase 1`.
  What to build: This is a verification-only item — no source code is written. The orchestrator hands the eight acceptance steps to the builder (Este) and waits for confirmation: (1) launch app from Xcode, (2) verify toolbar layout (Multi-instance · Layout · Cycler · Games · Settings · More), (3) verify menu structure with no Roblox windows + alert on tile-with-zero-windows, (4) launch 4 RORORO accounts → Tile → Auto-grid → expect 2×2 fills active screen, (5) verify 3×3 / Row / Column / Auto-grid round trip, (6) verify cycler-state gating (Tile items disabled while cycler is `.running`), (7) verify multi-display behavior (drag RORORO to secondary display, tile on that display), (8) optional: verify TCC re-prompt path. After acceptance, log a 626 dashboard decision via `mcp__626Labs__manage_decisions log` titled "Window Layout Tool ships P1 (tile-only)" capturing: reused Accessibility TCC bucket → no new permission ask, AXWindowManager pattern ports from WindowFocuser, P1 valuable alone / P2 (shrink + custom) additive.
  Acceptance: All 8 manual steps pass. Dashboard decision logged with bound project ID.
  Verify: Builder confirms each numbered step in chat ("step 4: 2×2 looks right", etc.). Dashboard decision is searchable via `mcp__626Labs__manage_decisions search` and shows the new entry with this date stamp.
