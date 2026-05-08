# ADR 0003 — Serial launch queue

**Date:** 2026-05-08
**Status:** Accepted
**Slope:** B-α (Account vault polish, foundation step)

## Context

Manual smoke testing of multi-instance launches surfaced collisions when the user clicked Launch As across multiple accounts in rapid succession. Symptom: launches that work cleanly when triggered one-at-a-time fail or hang when triggered simultaneously. The user's manual workaround was to wait for each Roblox instance to settle before triggering the next — which works but doesn't scale to a future "Launch group" feature (Slope B1) where the explicit goal is N parallel launches from one click.

The Windows port (RORORO Windows / ROROROblox) does not exhibit this collision. Diagnosis dive:

**Mac multi-instance recipe** (`MultiInstanceCoordinator.performLaunch`):

1. Copy `/Applications/Roblox.app` → `~/Applications/RORORO/instances/<uuid>.app/` (~600 MB)
2. `sem_unlink("/RobloxPlayerUniq")`
3. `/usr/bin/open -n -a <copy> <url>`
4. Modify Info.plist on the copy (defensive, post-launch)
5. `sem_unlink` again (race buffer)

**Windows multi-instance recipe** (per the sibling repo's `MutexHolder`): hold `Local\ROBLOX_singletonEvent` mutex; spawn from the original install. **No bundle copy.**

The 600 MB copy is the load-bearing difference. Two parallel Mac launches mean two parallel disk-heavy copies; the I/O contention drags both. Secondary collision: two parallel `sem_unlink` + spawn pairs leave a window where the second spawn's engine can race the first's semaphore re-creation.

## Decision

Introduce a serial launch queue inside `MultiInstanceCoordinator`. Every incoming `roblox-player:` URL goes through a single AsyncStream worker; the worker processes one launch at a time and waits for the spawned Roblox to register in `NSWorkspace.runningApplications` (or a 3 s grace, whichever first) before draining the next request.

Implementation shape:

```swift
private struct LaunchRequest: Sendable {
    let url: URL
    let enabled: Bool
    let semaphoreName: String
}
private var launchContinuation: AsyncStream<LaunchRequest>.Continuation?
private var launchWorkerTask: Task<Void, Never>?

// In bootIfNeeded():
let (stream, continuation) = AsyncStream<LaunchRequest>.makeStream(...)
self.launchContinuation = continuation
self.launchWorkerTask = Task.detached(priority: .userInitiated) {
    for await request in stream {
        let baseline = Self.runningRobloxPIDs()  // Set<pid_t>
        await Self.performLaunch(request.url, enabled: request.enabled, semaphoreName: request.semaphoreName)
        await Self.waitForLaunchToSettle(baseline: baseline)
    }
}

// In handleIncomingURL():
launchContinuation?.yield(LaunchRequest(...))
```

Settle-wait phases (load-bearing — initial 3 s wait was too short and let the next launch's disk thrash hit the previous engine's vulnerable boot window; smoke 2026-05-08 saw the first rapid-fire launch's window appear then close):

- **Phase 1 — appear (≤8 s).** Poll `NSWorkspace.runningApplications` every 100 ms until a Roblox PID outside the baseline set shows up.
- **Phase 2 — finish launching (≤20 s).** Wait for that PID's `NSRunningApplication.isFinishedLaunching` to become true (Cocoa's `applicationDidFinishLaunching` fires when the first window is responsive). Bail early if the process terminates.
- **Phase 3 — post-grace (2 s).** Settle window so the engine has time to do its first second of "I'm alive" work — network handshake, asset preloading, any semaphore-recreation defenses — before the next queued launch's `sem_unlink` + 600 MB copy lands.

Total per-launch dwell time settles around 12–15 s in practice. Slower than the original draft (3 s wait + 0.5 s grace) but matches the manual-wait cadence the user was already using by hand.

## Consequences

**Sequential clicks unchanged.** A single Launch As click still feels instant — the queue has one item, processes it, idles. No added latency.

**Rapid-fire clicks now serialize cleanly.** Two clicks in quick succession get queued; the second waits for the first's Roblox to register before its own copy step starts. Total wall time = sum of individual launch times rather than parallel-but-collided. Acceptable trade for correctness.

**Launch Group (Slope B1) becomes mechanical.** A future "Launch all in group" button enqueues N requests; the worker drains them one at a time with the buffer. No additional architecture needed.

**Per-account framerate divergence is now reliable.** ADR 0002 documented a "rapid-fire same-second launches converge to last-write-wins" caveat for `framerateCapOverride`. The settle-wait (Phase 1 + 2 + 3 ≈ 12–15 s) gives Roblox's engine startup a comfortable window to read `GlobalBasicSettings_<N>.xml` before the next queued launch's XML write lands. The race is no longer "documented limitation" — it's mitigated.

**Pre-boot fallback.** If `handleIncomingURL` somehow fires before `bootIfNeeded` (e.g., a `roblox-player:` URL routed via `.onOpenURL` before `.onAppear` runs — should be impossible in practice but the SwiftUI lifecycle isn't a contract), we fall back to the prior `Task.detached` direct dispatch so launches aren't silently dropped. Logged as a known fallback path.

**Testing.** The queue is internal plumbing; existing `MultiInstanceCoordinator` tests pass unchanged. A unit test for `waitForRobloxIncrease` is non-trivial (requires `NSWorkspace` mocking); deferred to integration smoke when Launch Group ships.

## Implementation map

| File | Change |
| --- | --- |
| `App/RORORO/Domain/MultiInstanceCoordinator.swift` | `LaunchRequest` struct, `launchContinuation`, `launchWorkerTask`, AsyncStream boot in `bootIfNeeded`, `handleIncomingURL` yields to queue, `runningRobloxPIDs` + three-phase `waitForLaunchToSettle` (appear / `isFinishedLaunching` / post-grace) |

## Open follow-ups

- **Per-launch UI state**: when N launches are queued, accounts past the head of the queue should show "queued" rather than "launching" or "ready." Today the existing per-row `inFlightLaunchUserId` clears as soon as `RobloxLauncher.shared.launch` returns (which now happens at queue-yield time, not at spawn time). Minor UX bug — addressed when Slope B1 (Launch Group) ships, since that's where queue-state visibility matters.
- **Pool of pre-made copies** as a future optimization: copy 4–5 spare Roblox.app instances at app boot, hand them out instantly per launch. Cuts the 5–10 s copy delay per launch entirely. Cache invalidation when Roblox auto-updates the source bundle is the open design question. Deferred until the queue's per-launch latency is the user's biggest pain.
