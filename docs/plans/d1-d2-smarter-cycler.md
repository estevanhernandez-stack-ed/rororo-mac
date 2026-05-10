# Plan — Slope D, Waves 1 + 2: Smarter cycler

**Date:** 2026-05-10
**Status:** In flight
**Slope:** D — smarter cycler. D-1 (pacing + delivery confidence) and D-2 (smarter pause) ship in one PR. D-3 (full-fidelity record-and-replay, ADR 0007 Draft) is a separate wave.

## Why this slope

Two friction patterns observed in the live cycler:

1. **Keystrokes occasionally don't land.** The cycler focuses a window then fires keys — but `WindowFocuser.focus` only verifies the *process* is frontmost, not the *focused window*. If a process is frontmost but its main window is minimized or a different sub-window is focused, keys route to the wrong place. (`WindowFocuser.swift:96-118`)
2. **Mouse pause is too eager + focus-theft is invisible.** Any mouse twitch pauses the cycler (`AutoKeysSafetyMonitor.swift:106-107`), including movement *inside* the Roblox window the user is actively playing. And if Safari steals focus mid-cycle, the cycler keeps firing keys into the wrong app until the next iteration.

User intent (confirmed in chat): **defensive + UX safety, not anti-detection.** Stop firing into wrong targets; surface the state change to the user. No detection evasion.

## Shared substrate — `WindowRectTracker`

Both waves depend on a new actor:

```swift
public actor WindowRectTracker {
    private var rects: [pid_t: CGRect] = [:]

    /// Refresh the cached rect for `pid` via AX (kAXPositionAttribute +
    /// kAXSizeAttribute on the focused window). Called by the cycler
    /// after a successful focus.
    public func refresh(pid: pid_t) async

    /// Lookup. nil if pid is not currently tracked or AX read failed
    /// last refresh.
    public func rect(for pid: pid_t) -> CGRect?

    /// Returns the pid whose rect contains `point`, or nil if none.
    /// Used by D-2's mouseMoved gating.
    public func contains(point: CGPoint) -> pid_t?

    /// All currently-tracked pids. Used by D-2's focus-theft check.
    public func currentPids() -> [pid_t]

    /// Drop a pid from the cache. Called when the cycler skips a target
    /// (focus-failure) and when a target's process exits.
    public func forget(pid: pid_t)

    /// Drop everything. Called on cycler stop.
    public func reset()
}
```

**Coord-system gotcha to bake in:** `NSEvent.mouseLocation` returns bottom-left-origin screen coords; AX `kAXPositionAttribute` returns top-left-origin. The tracker normalizes everything to top-left at refresh time so callers can compare directly to `NSEvent.mouseLocation` after one flip in the safety monitor.

Lives at `App/RORORO/Domain/AutoKeys/WindowRectTracker.swift`. New file, no naming conflicts (audit confirmed).

## Wave D-1 — Pacing + delivery confidence

### D-1.1 Extend `WindowFocuser.focus` verification (`WindowFocuser.swift:99-118`)

After the existing frontmost poll succeeds, additionally verify:

- `kAXFocusedWindowAttribute` on the app element equals `kAXMainWindow` (i.e., the focused window is the main window we expect to receive input).
- `kAXMinimizedAttribute` on that window is `false`.

If either check fails: log + proceed anyway (additive behavior, no change to error semantics). The cycler still gets its chance to fire; we just have telemetry on the misroute case for next iteration's tuning.

### D-1.2 `WindowRectTracker` integration in the cycler

In `AutoKeysCycler.runLoop`, after `try await focuser.focus(pid: target.pid)` (line 301), call `await tracker.refresh(pid: target.pid)`. The tracker is injected into `AutoKeysCycler.init` alongside `focuser` (and shared with the safety monitor — see D-2).

On `forget(pid:)`: when `focuser.focus` throws `WindowFocuserError.notRunning`, also call `await tracker.forget(pid: target.pid)` so a dead pid doesn't linger in the cache.

On `reset()`: in `tearDown`, after assertion release, call `await tracker.reset()`.

### D-1.3 Post-fire focus verification (`AutoKeysCycler.swift:318-319`)

After `await poster.post(keyCode: step.keyCode)`, before the inter-press sleep:

```swift
let stillFront = await MainActor.run {
    NSWorkspace.shared.frontmostApplication?.processIdentifier
}
if stillFront != target.pid {
    NSLog("[RORORO] cycler: focus moved away from pid=\(target.pid) mid-sequence (now=\(stillFront ?? -1)); aborting remaining steps")
    break  // exits both the repeat loop and the step loop for this target
}
```

The `break` exits the innermost `for repeatIdx` loop; we also need a labeled break or a flag to exit the outer `for step in target.sequence.steps` loop. Cleaner: hoist the check + flag.

### D-1.4 Inter-press floor — non-issue

Audit confirmed `AutoKeysStep.intraRepeatInterval = 0.7` (700ms) already exceeds the 50ms floor I was worried about. Drop this item.

## Wave D-2 — Smarter pause

### D-2.1 Add `.focusStolen(byPid: pid_t)` to `EngagementEvent` (`AutoKeysSafetyConfig.swift:134-143`)

```swift
public enum EngagementEvent: Equatable, Sendable {
    case userEngaged
    case killRequested
    case focusStolen(byPid: pid_t)
}
```

### D-2.2 Add `.focusStolen(byPid:)` to `PauseReason` (nested in `AutoKeysCycler.swift:53-56`)

```swift
public enum PauseReason: Equatable, Sendable {
    case userEngaged
    case userRequested
    case focusStolen(byPid: pid_t)
}
```

**Semantic difference from `.userEngaged`:** `focusStolen` does NOT auto-resume. The user must press Play again or kill. Rationale: focus-theft is a "wait, where are we?" signal, not a "nudged the mouse" signal. Auto-resuming when focus returns to a Roblox window would surprise the user mid-task-switch.

`AutoKeysCycler.handleSafetyEvent` adds:
```swift
case .focusStolen(let byPid):
    switch state {
    case .running:
        engagementDeadline = nil  // no auto-resume
        updateState(.paused(reason: .focusStolen(byPid: byPid), until: nil))
    case .stopped, .paused:
        return
    }
```

`AutoKeysCycler.waitWhilePaused` adds the new case alongside `.userRequested`:
```swift
case .paused(.focusStolen, _):
    try? await sleeper.sleep(seconds: 0.25)
```

### D-2.3 Mouse-in-rect gating (`AutoKeysSafetyMonitor.swift:106-107`)

Inject `WindowRectTracker` into `AutoKeysSafetyMonitor.init`. Pass nil for unit tests that don't care.

On `.mouseMoved`:
```swift
case .mouseMoved:
    // Get current cursor position in screen coords (top-left after flip).
    let cursor = await MainActor.run { NSEvent.mouseLocation }  // bottom-left
    let height = await MainActor.run { NSScreen.main?.frame.height ?? 0 }
    let flipped = CGPoint(x: cursor.x, y: height - cursor.y)  // top-left
    if let tracker, await tracker.contains(point: flipped) != nil {
        return  // cursor is inside a tracked Roblox window — don't engage
    }
    broadcast(.userEngaged)
```

### D-2.4 NSWorkspace focus-theft observer

Following the pattern at `MultiInstanceCoordinator.swift:30-50` (which already uses `NSWorkspace.shared.notificationCenter`).

Owner: `AutoKeysSafetyMonitor`. The monitor subscribes in `start()` and removes the observer in `stop()`. It already manages process-lifetime input observation; focus-theft is a natural extension.

```swift
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil,
    queue: nil
) { [weak self] notification in
    guard let self,
          let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    else { return }
    Task { await self.handleAppActivation(pid: app.processIdentifier) }
}
```

`handleAppActivation`:
```swift
private func handleAppActivation(pid: pid_t) async {
    let ownPid = getpid()
    if pid == ownPid { return }  // we activated ourselves; ignore
    guard let tracker else { return }
    let tracked = await tracker.currentPids()
    if tracked.contains(pid) { return }  // moving between Roblox windows is fine
    broadcast(.focusStolen(byPid: pid))
}
```

### D-2.5 UI consumers

Four files need a new branch:

| File | What changes |
| --- | --- |
| `App/RORORO/UI/CyclerToolbarView.swift` (~lines 240-254) | Banner: "Paused — [AppName] took focus" with app name from `NSRunningApplication(processIdentifier:).localizedName ?? "another app"`. Color: amber (warning, not error). |
| `App/RORORO/UI/AutoKeysStatusPanel.swift` (~lines 222-234) | Dot color (amber) + headline ("Focus moved to [AppName]") |
| `App/RORORO/UI/TrayController.swift` (~lines 135-139) | Menu bar icon: same pause variant as `.userEngaged`, no new asset needed |
| `App/RORORO/UI/AutoKeysCyclerViewModel.swift` (~lines 258-276) | Branch for `.focusStolen` in the kill-key handler — same behavior as `.userRequested` (no auto-resume) |

## Test plan (TDD order)

Write tests first, then implementation. Order matches implementation order so each commit is a green-test landing.

### New file: `App/ROROROTests/WindowRectTrackerTests.swift`

- `refresh` populates the cache for a fake pid + rect
- `contains(point:)` returns the right pid for a point inside the rect
- `contains(point:)` returns nil for a point outside all rects
- `rect(for:)` returns the cached rect, nil for unknown pid
- `currentPids()` returns all tracked pids in arbitrary order
- `forget(pid:)` removes the entry
- `reset()` clears all

WindowRectTracker uses AX for production; tests use a synthesizable fake. The tracker itself is pure storage + AX call; the AX call goes behind a `WindowRectProvider` protocol with a fake conformance in tests.

### New file: `App/ROROROTests/WindowFocuserTests.swift`

Was missing per audit. Add a small suite that:
- Verifies `focus` calls AX setFrontmost (using a fake AX provider)
- Verifies the focused-window + minimized checks run after frontmost confirms
- Verifies fallback to `NSRunningApplication.activate` when AX fails

### Additions to `AutoKeysCyclerTests.swift`

- Post-fire focus theft → cycler aborts remaining steps for current target, continues to next target
- `.focusStolen` event → cycler pauses with `.focusStolen` reason, no auto-resume
- `.focusStolen` pause → wait for 5x resumeGrace, verify still paused
- Explicit `resume()` from `.focusStolen` → transitions to `.running`

### Additions to `AutoKeysSafetyMonitorTests.swift`

- `mouseMoved` with cursor inside tracked rect → no broadcast
- `mouseMoved` with cursor outside all tracked rects → broadcasts `.userEngaged`
- `mouseMoved` with nil tracker → broadcasts `.userEngaged` (legacy behavior preserved)
- Workspace activation with non-tracked PID, not RORORO → broadcasts `.focusStolen(byPid:)`
- Workspace activation with tracked PID → no broadcast
- Workspace activation with RORORO's own PID → no broadcast

NSWorkspace observer is harder to fake since it's wired into AppKit notifications. Two options:
1. Inject a `WorkspaceActivationObserver` protocol with a fake that the test drives directly.
2. Use `NotificationCenter.default.post` directly in the test.

Going with (1) — cleaner DI seam, matches the `EventTapping` pattern that's already in place.

## Order of work

1. `WindowRectTracker` — tests + impl + AX fake
2. `WindowFocuser` extension — tests + impl
3. `EngagementEvent.focusStolen` + `PauseReason.focusStolen` (data model changes — small, no behavior change yet)
4. `AutoKeysCycler.tracker` integration + post-fire focus check — tests + impl
5. `AutoKeysSafetyMonitor` mouseMoved gating — tests + impl
6. `AutoKeysSafetyMonitor` focus-theft observer + protocol — tests + impl
7. `AutoKeysCycler.handleSafetyEvent` + `waitWhilePaused` for `.focusStolen` — tests + impl
8. UI updates (4 files) — manual run + visual check
9. `xcodebuild test` full suite green
10. Update ADR 0004 with an amendment note pointing to this plan
11. Commit + verification

## Non-goals (out of scope for this slope)

- **D-3 work** — full-fidelity record-and-replay is ADR 0007 Draft, separate slope.
- **Mouse-event posting** — D-2 only *reads* mouse position. Posting mouse events lands in D-3.
- **Per-account focus-theft override** — for now `.focusStolen` is global. If users want "let me cmd-tab to Spotify without pausing," we add an allowlist in a follow-up.
- **Multi-display rect tracking** — `NSEvent.mouseLocation` and `NSScreen.main` cover the single-display case. Multi-display users get the same screen-flip behavior; if AX rects span screens, the math still works because we operate in global screen coords. Validated by manual test, not by automated coverage in this slope.

## Risks

- **AX read latency under load.** `kAXPositionAttribute` reads can stall briefly when the target app is busy. Mitigation: `WindowRectTracker.refresh` runs on the actor, doesn't block the cycler's loop synchronously; if the read times out, the rect goes stale until next iteration (acceptable — the mouseMoved gating just defaults to broadcasting userEngaged, which is the current behavior).
- **`NSEvent.mouseLocation` is main-thread-only.** Forced through `MainActor.run` in the safety monitor; adds a context hop per mouseMoved event. Cost is low (mouseMoved is throttled by NSEvent anyway) but worth a profile if friction shows up.
- **One-way break in `EngagementEvent`.** Adding a case is source-incompatible with any exhaustive switch outside the cycler/monitor. Audit confirmed no external consumers; if anything is missed, the compiler will catch it.

## References

- ADR 0004 — Auto-keys cycler (the current state). This plan amends Decision 9's pause posture.
- ADR 0007 Draft — Full-fidelity record-and-replay (the next wave; depends on `WindowRectTracker` from this slope).
- `App/RORORO/Domain/MultiInstanceCoordinator.swift:30-50` — pattern reference for NSWorkspace observer.
- `~/.claude/CLAUDE.md` hygiene rules — defensive posture only, no anti-detection.
