# Window Layout Tool — Design Spec

**Date:** 2026-05-09
**Status:** Approved (brainstorming → writing-plans)
**Companion ADR:** [`docs/decisions/0005-window-layout-tool.md`](../../decisions/0005-window-layout-tool.md)
**Author:** The Architect (autonomous, with Este in the loop)

---

## 1. Problem

A user running 4–9 Roblox accounts via RORORO has 4–9 full-size windows stacked on a single display. They can't see them all, can't quickly tile them, and can't proportionally shrink the set. Hand-arranging via Rectangle/Magnet works one window at a time, not a window-set operation. We need a *bulk* window action — "tile all my Roblox windows" or "shrink all my Roblox windows to 50%" — surfaced from RORORO's toolbar.

## 2. Goals

- **G1** — One-click tile of all RORORO-tracked Roblox windows into a regular grid (Auto-grid, 2×2, 3×3, 1×N row, N×1 column).
- **G2** — One-click proportional shrink (25/50/75/100%) preserving each window's current center.
- **G3** — Custom-size sheet for the rare non-preset case.
- **G4** — Zero new TCC permission asks (reuse Accessibility bucket already granted for AutoKeys).
- **G5** — Safe interaction with the AutoKeys cycler — no race conditions, no dropped keystrokes.

## 3. Non-goals

- **NG1** — Tiling external (non-RORORO) Roblox windows. RORORO-launched only.
- **NG2** — Spanning windows across multiple displays.
- **NG3** — Auto-rearranging on multi-instance toggle, account add/remove, or window count change.
- **NG4** — Persisted "remember last layout" preference. (P3+ if demand surfaces.)
- **NG5** — Global hotkeys. (P3+ if demand surfaces.)
- **NG6** — Per-account "resize this one window" affordance from `AccountsListView`. (P3+.)

## 4. Architecture

### 4.1 Component map

```text
┌─────────────────────────────────────────────────────────────────┐
│ UI Layer                                                         │
│                                                                  │
│  ContentView.toolbar                                             │
│    └─ WindowLayoutToolbarView  (Menu — Tile / Shrink / Custom)  │
│                                                                  │
│  WindowLayoutViewModel  (@Observable singleton)                  │
│    ├─ reads:  RunningAccountTracker.shared.pidsByUserId         │
│    ├─ reads:  AutoKeysCyclerViewModel.shared.state (gating)     │
│    └─ calls:  AXWindowManager + WindowLayoutPlanner             │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ Domain Layer (App/RORORO/Domain/WindowLayout/)                  │
│                                                                  │
│  AXWindowManager  (protocol + DefaultAXWindowManager impl)       │
│    ├─ mainWindowFrame(pid) -> CGRect                            │
│    └─ resize(pid, to: CGRect)                                   │
│         └─ AXUIElementSetAttributeValue                         │
│              kAXPositionAttribute + kAXSizeAttribute            │
│                                                                  │
│  WindowLayoutPlanner  (pure value type, no I/O)                 │
│    └─ static plan(mode, pids, screen, currentFrames)            │
│         -> [pid_t: CGRect]                                      │
│                                                                  │
│  LayoutMode  (enum)                                             │
│    ├─ .grid(cols: Int, rows: Int)                               │
│    ├─ .autoGrid                                                 │
│    └─ .shrink(percent: Double)                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 Why this shape

- **Domain / UI separation** matches existing project conventions (see `Domain/AutoKeys/` vs `UI/AutoKeysRecorderSheet.swift`).
- **Pure planner** — `WindowLayoutPlanner` is value-typed, no `AppKit` import. All grid + shrink math lives here, fully unit-testable without simulator or AX permissions.
- **Protocol-fronted manager** — `AXWindowManager` protocol allows test doubles (e.g., `RecordingAXWindowManager` that captures `resize` calls without actually moving windows). Mirrors the `WindowFocuser` protocol shape from Slope C.
- **Single VM** — one `WindowLayoutViewModel` rather than one per surface; the menu-driven action set is small and tightly coupled.

## 5. Data flow

### 5.1 User taps "Tile → Auto-grid"

```text
User → WindowLayoutToolbarView Menu item tap
     → WindowLayoutViewModel.applyAutoGrid()
        ├─ guard cycler.state != .running else { error alert; return }
        ├─ pids = RunningAccountTracker.shared.pidsByUserId.values (sorted by userId)
        ├─ screen = NSApp.mainWindow?.screen ?? NSScreen.main
        ├─ currentFrames = pids.map { try await axManager.mainWindowFrame(pid: $0) }
        ├─ plan = WindowLayoutPlanner.plan(.autoGrid, pids, screen, currentFrames)
        └─ for (pid, frame) in plan: try await axManager.resize(pid: pid, to: frame)
              └─ per-pid errors: log + continue (fail-soft)
```

### 5.2 User taps "Shrink → 50%" (P2)

Same flow, mode = `.shrink(percent: 0.50)`. Planner anchors each output frame at the input frame's center.

### 5.3 Cycler running → menu items disabled

```swift
WindowLayoutToolbarView body:
  Menu("Tile") {
    Button("Auto-grid") { vm.applyAutoGrid() }
      .disabled(cyclerIsRunning)
    ...
  }
  .help(cyclerIsRunning ? "Stop auto-keys to rearrange windows." : "Tile RORORO windows.")
```

`cyclerIsRunning` reads `AutoKeysCyclerViewModel.shared.state` reactively.

## 6. Error handling

| Failure | Behavior |
|---|---|
| `pid` no longer alive when resizing | Drop from layout, continue with the rest. Log `[RORORO] layout: pid=X notRunning, skipping`. |
| `kAXMainWindowAttribute` returns nil (Roblox mid-launch, no window yet) | Drop pid. Log `[RORORO] layout: pid=X noMainWindow, skipping`. |
| `AXUIElementSetAttributeValue` returns non-success | Log error code, continue with remaining pids. User sees windows that *did* resize; the failed ones stay where they were. |
| Accessibility TCC not granted | Reuse `AutoKeysPermissions.openAccessibilitySettings()` flow — same alert pattern as the cycler's preflight. |
| `NSApp.mainWindow == nil` (RORORO not foreground) | Fall back to `NSScreen.main`. Log warning. |
| Cycler in `.running` state | Menu items disabled at the UI layer; `applyAutoGrid()` etc. are guarded with an early-return as defense-in-depth. |

## 7. Testing

### 7.1 Unit (P1)

`Tests/RORORO/Domain/WindowLayoutPlannerTests.swift`:

- **Auto-grid math:** N=1, 2, 3, 4, 5, 6, 9, 16 — verify cols/rows + per-cell frame.
- **Explicit grid:** 2×2 with N=3 (3 filled, 1 empty), 3×3 with N=5, 1×4 (row), 4×1 (column).
- **Shrink math:** 25%, 50%, 75%, 100% — verify each output frame's center matches input frame's center, dimensions scaled correctly.
- **Edge cases:**
  - N=0 → empty plan (no-op).
  - Screen origin offset (e.g., menu bar present, dock visible) — ensure `NSScreen.visibleFrame` (not full `frame`) is used so windows tile inside the usable area, not under the dock.
  - Non-square screen ratios — verify cell dimensions don't assume square.
- **Stable sort:** running same plan twice with same inputs yields identical output (userId-sorted pid order).

### 7.2 Integration / manual (P1 acceptance)

1. Launch 4 RORORO accounts. Verify 4 Roblox windows on screen.
2. Click Layout button → Tile → Auto-grid. Verify 2×2 fills the active screen, accounting for menu bar + dock.
3. Repeat with 3, 5, 9 accounts — verify ceil(sqrt) packing matches ADR Decision 4.
4. Start AutoKeys cycler → open Layout menu — verify Tile items disabled with tooltip.
5. Stop cycler → verify Tile items re-enabled.
6. Drag RORORO to secondary display → tile → verify windows tile on secondary display.
7. Revoke Accessibility TCC → tile → verify graceful re-prompt flow (mirrors AutoKeys).

### 7.3 P2 additions (deferred)

- Shrink anchor verification — manually drag a window to (100, 100), shrink 50%, verify center preserved.
- Custom slider sheet — drag slider, verify live label updates, Apply commits, Cancel reverts to no-op.

## 8. Phased delivery

### Phase 1 (this spec's scope)

**Deliverables:**
- `App/RORORO/Domain/WindowLayout/LayoutMode.swift` — enum.
- `App/RORORO/Domain/WindowLayout/AXWindowManager.swift` — protocol + default impl.
- `App/RORORO/Domain/WindowLayout/WindowLayoutPlanner.swift` — pure planner.
- `App/RORORO/UI/WindowLayoutViewModel.swift` — @Observable VM.
- `App/RORORO/UI/WindowLayoutToolbarView.swift` — Menu button.
- `App/RORORO/UI/ContentView.swift` — one-line toolbar insert.
- `Tests/RORORO/Domain/WindowLayoutPlannerTests.swift` — planner unit tests.

**Out of P1 (visible-but-disabled in menu):**
- Shrink submenu (25/50/75/100%) — present, disabled, "Coming soon" tooltip.
- Custom Size… menu item — present, disabled.

**Acceptance:**
- All 5 Tile modes work on 4-account run.
- Cycler-state gating verified.
- Unit tests pass.
- Build clean (`xcodebuild -scheme RORORO build`).

### Phase 2

- Enable Shrink submenu — wire up the four percent presets to the existing planner.
- Add Custom Size sheet — slider (10–100%) + Apply/Cancel.

### Phase 3 (demand-driven)

- Per-account row context menu in `AccountsListView` ("Resize this window").
- Global hotkeys (Cmd+Opt+G = Auto-grid, Cmd+Opt+1 = full, etc.).
- "Remember last layout" preference — auto-apply on app launch when N matches.
- Toggle for "include external Roblox windows" — system-wide AX scan path.

## 9. Open questions

None at write-time. All assumptions stated in ADR 0005 (Decisions 1–6).

## 10. References

- [ADR 0005 — Window layout tool](../../decisions/0005-window-layout-tool.md)
- [ADR 0004 — Auto-keys cycler](../../decisions/0004-auto-keys-cycler.md) — cycler state machine + AX TCC posture.
- [ADR 0001 — Launch settings writers](../../decisions/0001-launch-settings-writers.md) — atomic-write + fail-soft pattern.
- `App/RORORO/Domain/AutoKeys/WindowFocuser.swift` — proven AX window-attribute pattern.
- `App/RORORO/Domain/RunningAccountTracker.swift` — canonical pid set.
- `App/RORORO/Domain/AutoKeys/AutoKeysPermissions.swift` — TCC re-prompt flow to reuse.
