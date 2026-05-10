# ADR 0005 — Window layout tool (tile + shrink)

**Date:** 2026-05-09
**Status:** Accepted
**Slope:** D (window management) — first ADR on a new slope; sits beside Slope C (auto-keys) but with no functional dependency.
**Spike:** None — codebase already proves out the AX window-manipulation surface via `WindowFocuser` (Slope C wave 1).

## Background

RORORO Mac runs N concurrent Roblox windows when multi-instance is enabled. A user with 4–9 accounts running has 4–9 full-size Roblox windows on a single display, each defaulting to `~1280×720` or whatever the last in-game setting was. The headline pains:

1. **Visibility.** Windows stack; only the frontmost is visible. The cycler focuses one at a time, but the user can't *see* the other windows to spot trouble (frozen, captcha, kicked).
2. **Manual tiling is tedious.** Dragging and corner-resizing 4 windows by hand is slow; doing it every session is friction. Window managers (Rectangle, Magnet) help with single-window snap but not "tile *these specific* windows in a grid."
3. **No "shrink to fit."** A user who wants 4 small windows visible at once needs to manually resize each. There's no proportional-shrink action across a window set.

The project already uses macOS Accessibility API for cross-app focus (`WindowFocuser` — Slope C wave 1, ADR 0004 Decision 1). Window resize/move uses the **same** AX surface (`AXUIElementSetAttributeValue` against `kAXPositionAttribute` + `kAXSizeAttribute`), so this is a no-new-permission feature.

## Decision 1 — Window scope: RORORO-launched processes only

**Decision:** The window layout tool operates exclusively on Roblox processes registered in `RunningAccountTracker.pidsByUserId`. External Roblox processes (launched outside RORORO — e.g., via the Roblox app icon, or via a different RORORO install) are not enumerated and not touched.

**Rationale:** Matches the existing AutoKeys cycler's enumeration model. `RunningAccountTracker` is the canonical pid set for "Roblox windows RORORO knows about." A system-wide AX scan would catch external windows too but introduces ambiguity — the user might intentionally have a separate Roblox session they don't want resized. Deterministic scope wins.

**Consequences:** A user with one Roblox window launched via Spotlight and three via RORORO will see only the three RORORO windows tiled. The Spotlight-launched window stays where it is. Documented behavior, not a bug. If demand surfaces for "tile all Roblox windows on this Mac," we add a toggle in P3+ rather than changing the default.

## Decision 2 — Display selection: screen containing RORORO's main window

**Decision:** Tile/shrink target frames are computed against `NSScreen` containing RORORO's main window (`NSApp.mainWindow.screen`). Multi-monitor users get tile-on-current-display semantics, not span-across-displays.

**Rationale:** Predictable. Matches Rectangle / Magnet defaults. Spanning across displays is rare in the multi-Roblox use case (users actively monitoring 4 windows want them in one viewport). Tiling across the same display where the launcher lives is the strongest "current focus = this display" signal.

**Consequences:** A user dragging RORORO to a secondary display, then triggering Auto-grid, gets the windows tiled on the secondary display. Roblox windows that started on a different display are moved to RORORO's display as part of the tile. Documented; matches user intent ("rearrange the windows where I'm looking").

## Decision 3 — Cycler-state gating: block Tile/Shrink while AutoKeys is .running

**Decision:** All Tile and Shrink menu items are disabled when `AutoKeysCyclerViewModel.shared.state == .running`. Tooltip on disabled items: "Stop auto-keys to rearrange windows."

**Rationale:** The cycler walks pid → focus → settle → fire keys on a tight schedule (Slope C wave 1, ADR 0004 Decision 6). Concurrent window resize while the cycler is mid-iteration introduces a race: the AX position-set takes a beat to land, and during that beat the cycler may have already re-focused a different window or fired keys against a window mid-resize. Output: dropped keystrokes, mis-routed input, or worse — keys sent to a window that just got moved out from under the cursor heuristic.

The clean rule: **window mutation and focus mutation don't run concurrently.** Block the layout actions while cycler is running. Paused or stopped state is fine — pause stops focus changes.

**Consequences:** User who wants to rearrange mid-session must hit Stop (toolbar's red square), tile, then Play again. Two extra clicks; acceptable for the integrity guarantee. The toolbar's existing "Stop" affordance is one tap from any state, so the friction is bounded.

## Decision 4 — Auto-grid algorithm: ceil(sqrt(N)) packing, row-major fill

**Decision:** For N RORORO-tracked Roblox windows, the Auto-grid mode computes:
- `cols = ceil(sqrt(N))`
- `rows = ceil(N / cols)`
- Cell size: `NSScreen.visibleFrame.width / cols` × `NSScreen.visibleFrame.height / rows` (`visibleFrame` excludes menu bar + dock — windows tile inside the actually-usable area, not under the dock)
- Window order: sorted by userId (stable across sessions)
- Fill: row-major, top-left first

**Rationale:** Single most-common multi-instance counts: 2, 3, 4, 6, 9. The packing yields:
- N=1 → 1×1 (full screen)
- N=2 → 2×1 (side by side)
- N=3 → 2×2 with bottom-right empty
- N=4 → 2×2
- N=5 → 3×2 with bottom-right empty
- N=6 → 3×2
- N=9 → 3×3

These are the layouts users actually want. ceil(sqrt) is the standard tile-N formula in window managers (PaperWM, Tridactyl, etc.). Stable sort by userId means the same account always lands in the same cell across runs — useful for "the top-left is always my main."

**Consequences:** N=3 has one empty cell; the user can drag the bottom-right Roblox window into it manually if they prefer 3-up. N=5 same. We don't auto-stretch the bottom row to fill — that introduces non-uniform cell sizes which look messy. Documented; trivial to add a "tight 3-up" preset later if requested.

## Decision 5 — Shrink anchor: each window's current center  [RETRACTED 2026-05-10]

> **Retracted in Decision 7.** Roblox's macOS player enforces a hardcoded ~800×600 window minimum that AX size-set silently rejects below. Shrink fundamentally cannot deliver value on Roblox; replaced by Cascade.

**Original decision (preserved for context):** The Shrink mode (25/50/75/100%) scales each window around its own current center, not around screen center or screen origin. A window currently at `(x: 200, y: 100, w: 1280, h: 720)` shrunk to 50% becomes `(x: 520, y: 280, w: 640, h: 360)` — same center, half-size.

**Original rationale (preserved):** Preserves the user's manual arrangement. If they've already dragged windows into a layout that works, Shrink lets them just make everything proportionally smaller without disturbing the spatial relationships. Anchoring at screen origin would pile every window into the top-left corner; anchoring at screen center would crowd the center. Per-window center anchoring is the only mode that respects existing layout.

## Decision 6 — Stateless: no remember-last-layout

**Decision:** The layout tool is action-only. No persisted state for "last applied layout," no auto-restore on app launch, no preference for "default tile mode."

**Rationale:** It's an action, not a preference. The user picks a tile when they want one. Persistence is feature-bloat for a v1 — adds the "settings page entry," "what if the screen geometry changed since last save," and "how does it interact with multi-instance toggle on/off" questions. None of those have load-bearing answers in P1. Defer until demand surfaces.

**Consequences:** Each session starts with whatever Roblox window sizes Roblox itself chose. User re-applies their preferred tile when they want it. If demand surfaces ("I always tile 2×2 — why doesn't it remember"), P3 adds a "default layout on launch" preference; the action skill stays exactly the same.

## Decision 7 — Shrink retracted; Cascade added (2026-05-10)

**Decision:** Remove the Shrink mode entirely from the toolbar, planner, and tests. Replace with Cascade — a position-only staircase arrangement. Also retract P2.5 (the StartScreenSize XML writer that was an attempt to lower the shrink floor at launch).

**Rationale:** Empirical investigation during P1 manual acceptance surfaced that Roblox's macOS player binary enforces a hardcoded **~800×600 minimum window size**. The constraint is engine-level, not OS-level — verified three ways:

1. **Direct AX test:** AX size-set with target below 800×600 returns `.success` but the window snaps back to 800×600. Console log: `asked (200, 157), got (800, 628)`.
2. **Rectangle truth-test (MIT, [github.com/rxhanson/Rectangle](https://github.com/rxhanson/Rectangle)):** Same AX call surface as ours. Cannot shrink Roblox below the floor either. Confirmed not a RORORO implementation gap.
3. **Moom truth-test (closed-source, commercial):** Same constraint. Engine-level, not toolkit-specific.

**P2.5 retracted simultaneously:** The `StartScreenSize` XML field (`<Vector2 name="StartScreenSize">` in `GlobalBasicSettings_<N>.xml`) looked like a plausible launch-time lever — its default value (800, 600) matched the observed snap-back floor. RORORO wrote 640×480 to it; the file write succeeded, was confirmed on disk, and Roblox subsequently launched at... 800×600. The field doesn't control player window dimensions; it appears to be a Studio-only setting. P2.5 plumbing (writer + store field + launcher wire-in + UI submenu) all removed.

**Cascade replaces Shrink:** The user's underlying ask was *better visibility into multiple grinding windows*. Shrink would've delivered that by making each window smaller. With shrink dead, Cascade delivers the same goal differently — staircase arrangement where every title bar peeks out from behind the previous window. Position-only operation, sidesteps the floor entirely. Each window keeps its current size; only positions move. Default offset (40, 40) per window; wraps to a new column at 200 px right when the stack exceeds the visible-rect height.

**Consequences:**
- The Layout menu's Shrink submenu and Custom Size item are gone. Tile submenu now ends with a Cascade item.
- Users wanting smaller individual windows can drag-resize manually — the floor still applies, but at least there's no agent claiming it can do something it can't.
- The retraction is preserved in the codebase commit log (commit `d7082b4`) and in the planner's removed `.shrink` enum case + tests.
- Future investigation could probe Roblox's render-engine FFlags for a min-size override (Hyperion locks the FFlag write surface for most flags, so this is research territory, not an implementation task).
- ADR 0001 Decision 2's `ClientSettingsWriter` surface remains valid for *other* FFlag injection (graphics quality, render path) — this retraction is scoped to the StartScreenSize lever specifically.

## Implementation map

| Layer | File | What it does |
| --- | --- | --- |
| Domain — service | `App/RORORO/Domain/WindowLayout/AXWindowManager.swift` | Protocol + `DefaultAXWindowManager` impl. `resize(pid:to:)` and `mainWindowFrame(pid:)`. Wraps `AXUIElementSetAttributeValue` with `kAXPositionAttribute`/`kAXSizeAttribute`. Throws on AX failure; caller decides fail-soft. |
| Domain — pure logic | `App/RORORO/Domain/WindowLayout/WindowLayoutPlanner.swift` | Pure value type. `static plan(mode:pids:screen:currentFrames:) -> [pid_t: CGRect]`. No I/O — fully unit-testable. Owns the auto-grid math + shrink math. |
| Domain — modes | `App/RORORO/Domain/WindowLayout/LayoutMode.swift` | Enum: `.grid(cols, rows)`, `.autoGrid`, `.shrink(percent)`. |
| UI — view model | `App/RORORO/UI/WindowLayoutViewModel.swift` | `@Observable` singleton. Reads pids from `RunningAccountTracker.shared`, current frames from `AXWindowManager`, dispatches plan, applies. Error alert pattern reused from `AutoKeysCyclerViewModel`. |
| UI — toolbar | `App/RORORO/UI/WindowLayoutToolbarView.swift` | Menu button. Sits between multi-instance toggle and `CyclerToolbarView` in `ContentView.toolbar`. Tile submenu enabled in P1; Shrink + Custom items present but disabled (label: "Coming soon") in P1. |
| UI — wiring | `App/RORORO/UI/ContentView.swift` (diff) | One-line insert into `ToolbarItemGroup`: `WindowLayoutToolbarView()` between `multiInstanceToggle` and `CyclerToolbarView()`. |
| Tests | `Tests/RORORO/Domain/WindowLayoutPlannerTests.swift` | Table-driven tests for grid math (N=1, 2, 3, 4, 5, 6, 9), shrink math (each percent), edge cases (N=0 → no-op, screen-origin variations). |

## Phasing

| Phase | Scope | Approval gate |
| --- | --- | --- |
| **P1** | Domain layer + Tile submenu (Auto-grid, 2×2, 3×3, Row, Column) + toolbar button + cycler-state gating + planner unit tests. Shrink + Custom items present in menu but disabled. | This ADR. |
| **P2** | Enable Shrink submenu (25/50/75/100%). Add Custom Size sheet (slider 10–100%, live preview optional). | Verify P1 ships clean; collect any usage feedback. |
| **P3** | Per-account row context menu in `AccountsListView` ("resize this window"). Global hotkeys (Cmd+Opt+1 = full, Cmd+Opt+2 = 2×2, etc.). Optional "remember last layout" preference. | Demand-driven only — none of these block headline use case. |

## References

- ADR 0001 — Launch settings writers (atomic write + fail-soft pattern).
- ADR 0004 — Auto-keys cycler (cycler state machine + AX TCC reuse).
- `App/RORORO/Domain/AutoKeys/WindowFocuser.swift` — proven AX window-attribute pattern this ADR extends from focus-only to position+size.
- `App/RORORO/Domain/RunningAccountTracker.swift` — pid source of truth.
