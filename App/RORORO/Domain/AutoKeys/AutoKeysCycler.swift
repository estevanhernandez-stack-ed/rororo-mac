// AutoKeysCycler.swift
// Domain — singleton actor that owns the auto-keys loop (Slope C).
//
// State machine (per ADR 0004 Decisions 6 + 9):
//
//   .stopped(reason?)
//        │ start()
//        ▼
//   .running(pids) ──┬──pause()──▶ .paused(.userRequested, nil)
//        │           │
//        │           └─safety.userEngaged──▶ .paused(.userEngaged, until: deadline)
//        │                                           │
//        │                                           └─grace expires──▶ .running
//        │
//        ├──stop()──▶ .stopped(.userRequested)
//        ├──safety.killRequested──▶ .stopped(.userKilled)
//        └──budget overflow mid-flight──▶ .stopped(.budgetExceeded)
//
// One full iteration walks `targets` serially: focus pid → fire each
// step's keystroke + sleep `step.delayAfter` → repeat for next target →
// then sleep `loopDelay` and re-iterate. A `WindowFocuser.notRunning`
// error skips that target for the rest of the iteration; the next
// iteration re-attempts. Before every iteration the cycler re-validates
// the snapshot through `CycleBudget` and stops itself if the cap is
// exceeded mid-flight (e.g. user reconfigured to push past 19 min).
//
// Safety: when a `safety` monitor is wired in, the cycler subscribes to
// its events on start and tears down the subscription on stop.
// `.userEngaged` ─▶ pause with auto-resume after `safety.config.resumeGrace`
// (extends on continued input). `.killRequested` ─▶ hard stop.

import AppKit
import CoreGraphics
import Foundation

public actor AutoKeysCycler {

    public enum State: Equatable, Sendable {
        case stopped(reason: StopReason?)
        case running(pids: [pid_t])
        /// Cycler is suspended. `until` is the auto-resume deadline for
        /// `.userEngaged` pauses; nil for `.userRequested` pauses (which
        /// only clear via an explicit `resume()` call).
        case paused(reason: PauseReason, until: Date?)
    }

    public enum StopReason: Equatable, Sendable {
        case userRequested
        case budgetExceeded(estimated: TimeInterval)
        case noTargetsConfigured
        case userKilled
    }

    public enum PauseReason: Equatable, Sendable {
        case userEngaged
        case userRequested
        /// D-2: focus moved to an app outside our cycle (not RORORO,
        /// not a tracked Roblox window). The cycler pauses without an
        /// auto-resume deadline — user must press Play again or kill.
        /// `byPid` is the pid of the app that took focus, surfaced in
        /// the toolbar banner via `NSRunningApplication.localizedName`.
        case focusStolen(byPid: pid_t)
    }

    public enum StartError: Error, Equatable {
        case budgetExceeded(estimated: TimeInterval, hardCap: TimeInterval)
    }

    /// One running Roblox window paired with its sequence. Built by the
    /// caller from `(Account.autoKeys, runningPid)` — the cycler doesn't
    /// know about accounts, only targets it can focus and fire at.
    public struct Target: Sendable, Equatable {
        public let pid: pid_t
        public let sequence: AutoKeysSequence
        /// Optional human-readable label for log lines.
        public let label: String?

        public init(pid: pid_t, sequence: AutoKeysSequence, label: String? = nil) {
            self.pid = pid
            self.sequence = sequence
            self.label = label
        }
    }

    public static let shared = AutoKeysCycler(
        poster: CGEventKeyEventPoster(),
        mousePoster: CGEventMouseEventPoster(),
        focuser: NSRunningApplicationFocuser(),
        assertion: IOPMPowerAssertion(),
        sleeper: TaskSleeper(),
        safety: AutoKeysSafetyMonitor.shared,
        tracker: WindowRectTracker.shared,
        frontmostAppProvider: NSWorkspaceFrontmostAppProvider()
    )

    private let poster: KeyEventPoster
    /// D-3.2 — mouse-event posting for the action-stream player. The
    /// legacy step path doesn't touch this. Tests pass a recording fake.
    private let mousePoster: MouseEventPoster
    private let focuser: WindowFocuser
    private let assertion: PowerAssertion
    private let sleeper: Sleeper
    /// Optional — production wires the real monitor; tests can pass nil
    /// to skip safety integration entirely, OR pass a fake monitor with
    /// a fake `EventTapping` to drive engagement / kill events.
    private let safety: AutoKeysSafetyMonitor?
    /// Optional — production wires the shared tracker. Refreshed on each
    /// successful focus, queried by the safety monitor for D-2 mouse
    /// gating + focus-theft detection. Tests can pass nil to skip the
    /// rect substrate entirely.
    private let tracker: WindowRectTracker?
    /// D-1 post-fire focus-theft probe. Production reads
    /// `NSWorkspace.frontmostApplication`; test fakes return whatever
    /// pid the fake focuser most recently "focused" so the check passes.
    private let frontmostAppProvider: FrontmostAppProvider

    public private(set) var state: State = .stopped(reason: nil)
    private var loopTask: Task<Void, Never>?
    private var safetyTask: Task<Void, Never>?
    private var stateContinuations: [UUID: AsyncStream<State>.Continuation] = [:]
    /// Per-iteration progress callback — fires whenever the cycler
    /// advances between targets OR posts a key, so the view-model can
    /// show "firing W on Alice, next: Bob" without polling. Sendable
    /// so it can be invoked from the actor's isolation.
    ///
    /// `currentKeyCode` is the code of the key being pressed at this
    /// instant (or nil between steps / between iterations).
    public typealias ProgressCallback = @Sendable (
        _ current: String?,
        _ next: String?,
        _ currentKeyCode: CGKeyCode?
    ) -> Void
    private var progressCallback: ProgressCallback?

    /// Auto-resume deadline for engagement pauses. Nil iff not currently
    /// paused (or paused with `.userRequested`, which has no deadline).
    private var engagementDeadline: Date?
    /// Resume-grace from the safety config; cached at start so the loop
    /// doesn't have to call back into the safety monitor on every event.
    private var resumeGrace: TimeInterval = 5.0
    /// PIDs we're cycling over — kept around so we can transition back
    /// to `.running(pids)` after a pause clears.
    private var currentPids: [pid_t] = []

    public init(
        poster: KeyEventPoster,
        mousePoster: MouseEventPoster = CGEventMouseEventPoster(),
        focuser: WindowFocuser,
        assertion: PowerAssertion,
        sleeper: Sleeper,
        safety: AutoKeysSafetyMonitor? = nil,
        tracker: WindowRectTracker? = nil,
        frontmostAppProvider: FrontmostAppProvider = NSWorkspaceFrontmostAppProvider()
    ) {
        self.poster = poster
        self.mousePoster = mousePoster
        self.focuser = focuser
        self.assertion = assertion
        self.sleeper = sleeper
        self.safety = safety
        self.tracker = tracker
        self.frontmostAppProvider = frontmostAppProvider
    }

    // MARK: - Public API

    /// Begin cycling over `accounts`. Refuses to start if the estimated
    /// cycle time exceeds `CycleBudget.hardCap`. Restarts cleanly if
    /// already running.
    public func start(accounts: [Target], loopDelay: TimeInterval) async throws {
        if loopTask != nil || safetyTask != nil {
            await tearDown(reason: .userRequested)
        }

        let snapshot = accounts.map(\.sequence)
        let estimate = CycleBudget.estimate(snapshot: snapshot, loopDelay: loopDelay)
        guard CycleBudget.state(for: estimate) != .overCap else {
            throw StartError.budgetExceeded(
                estimated: estimate,
                hardCap: CycleBudget.hardCap
            )
        }

        let active = accounts.filter { !$0.sequence.isEmpty }
        guard !active.isEmpty else {
            updateState(.stopped(reason: .noTargetsConfigured))
            return
        }

        try assertion.acquire(reason: "RORORO auto-keys cycler running")
        let pids = active.map(\.pid)
        currentPids = pids
        engagementDeadline = nil
        let summary = active.map { "\($0.label ?? "?")[pid=\($0.pid),steps=\($0.sequence.steps.count)]" }.joined(separator: ", ")
        NSLog("[RORORO] cycler: starting with \(active.count) target(s): \(summary), loopDelay=\(loopDelay)s")

        // Race-fix (user-reported 2026-05-10) — pre-populate the rect
        // tracker for EVERY target before any focus call fires. Without
        // this, focusing the second window races the safety monitor's
        // focus-theft observer: macOS fires the activation event for
        // pid N+1 before the cycler's own `tracker.refresh(pid:)` runs
        // for it, so the observer sees pid N+1 NOT in `tracker
        // .currentPids()` → flags it as theft → pauses the cycler
        // immediately. Pre-populating means every cycled pid is
        // already "tracked" when its first activation event lands.
        if let tracker {
            for target in active {
                await tracker.refresh(pid: target.pid)
            }
        }
        updateState(.running(pids: pids))

        // Subscribe to safety events BEFORE the loop spawns so the very
        // first engagement event we'd care about doesn't slip past us.
        // Lifecycle (start/stop) of the monitor is owned by the
        // view-model — it runs whenever Input Monitoring is granted, not
        // just while we're running. We just attach a subscription here.
        if let safety {
            let stream = await safety.observe()
            safetyTask = Task { [weak self] in
                for await event in stream {
                    if Task.isCancelled { return }
                    await self?.handleSafetyEvent(event)
                }
            }
        }

        loopTask = Task { [weak self] in
            await self?.runLoop(accounts: active, loopDelay: loopDelay)
        }
    }

    /// Explicit user pause (toolbar Pause button). No auto-resume — only
    /// a matching `resume()` or `stop()` clears it. No-op if not running.
    public func pause() {
        guard case .running = state else { return }
        engagementDeadline = nil
        updateState(.paused(reason: .userRequested, until: nil))
    }

    /// Explicit user resume. Transitions back to `.running` from any
    /// paused state (engagement or user-requested). No-op if not paused.
    public func resume() {
        guard case .paused = state else { return }
        engagementDeadline = nil
        updateState(.running(pids: currentPids))
    }

    /// Stop the cycler — cancels loop + safety subscriptions, releases
    /// the wake-lock, transitions to `.stopped(reason)`. Default reason
    /// is `.userRequested`; the view-model passes `.userKilled` when
    /// the kill gesture triggered the stop, so the toolbar can render
    /// the right end-state.
    public func stop(reason: StopReason = .userRequested) async {
        await tearDown(reason: reason)
    }

    /// Register a progress callback. Replaces any prior callback.
    /// View-model calls this once at init to wire its current/next
    /// state mirroring.
    public func setProgressCallback(_ callback: ProgressCallback?) {
        self.progressCallback = callback
    }

    public func observe() -> AsyncStream<State> {
        AsyncStream { continuation in
            let id = UUID()
            stateContinuations[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    // MARK: - Safety integration

    private func handleSafetyEvent(_ event: EngagementEvent) async {
        switch event {
        case .userEngaged:
            // Pause-on-engagement: only fires the FIRST event that
            // transitions us from running → paused. Subsequent events
            // while already paused do NOT extend the deadline — the
            // user complained that any mouse movement kept the pause
            // active forever, which made the toolbar unreachable.
            // Non-extending pause means: 1.5s after first engagement,
            // we auto-resume regardless of continued mouse activity.
            switch state {
            case .running:
                let deadline = Date().addingTimeInterval(resumeGrace)
                engagementDeadline = deadline
                updateState(.paused(reason: .userEngaged, until: deadline))
            case .stopped, .paused:
                return
            }

        case .killRequested:
            // No-op — kill handling moved to AutoKeysCyclerViewModel
            // so the start (from .stopped) and stop (from .running /
            // .paused) decisions live in one place. Two parallel
            // handlers (cycler + view-model) caused a race where
            // cycler tore down first → state became .stopped(.userKilled)
            // → view-model saw .stopped → called play() → restart loop.
            return

        case .focusStolen(let byPid):
            // D-2: focus moved to an app we don't own and aren't
            // cycling. Unlike `.userEngaged` (which auto-resumes after
            // resumeGrace), focusStolen has no deadline — the user
            // must explicitly resume. Rationale: a mouse twitch is a
            // "nudge," focus theft is "where are we?" — auto-resuming
            // mid-task-switch would surprise the user.
            switch state {
            case .running:
                engagementDeadline = nil
                updateState(.paused(reason: .focusStolen(byPid: byPid), until: nil))
            case .stopped, .paused:
                return
            }
        }
    }

    // MARK: - Internal loop

    private func runLoop(accounts: [Target], loopDelay: TimeInterval) async {
        // Pull resume grace from the safety config once at start so the
        // engagement handler isn't async-bouncing through the monitor on
        // every event.
        if let safety {
            resumeGrace = await safety.currentConfig().resumeGrace
        }

        while !Task.isCancelled {
            await waitWhilePaused()
            if Task.isCancelled { return }

            // Re-validate budget. Reconfiguration mid-flight to push
            // past the cap bails out cleanly.
            let snapshot = accounts.map(\.sequence)
            let estimate = CycleBudget.estimate(snapshot: snapshot, loopDelay: loopDelay)
            if CycleBudget.state(for: estimate) == .overCap {
                await tearDown(reason: .budgetExceeded(estimated: estimate))
                return
            }

            for (idx, target) in accounts.enumerated() {
                if Task.isCancelled { return }
                await waitWhilePaused()
                if Task.isCancelled { return }
                if target.sequence.isEmpty { continue }
                // Fire the progress callback so the toolbar can show
                // "now: X, next: Y". next wraps to first on the last
                // index — that's the next iteration's first target.
                let nextIdx = (idx + 1) % accounts.count
                let nextLabel = accounts[nextIdx].label
                progressCallback?(target.label, nextLabel, nil)
                NSLog("[RORORO] cycler: focusing pid=\(target.pid) (\(target.label ?? "?"))")
                do {
                    try await focuser.focus(pid: target.pid)
                } catch {
                    NSLog("[RORORO] cycler: skipping pid=\(target.pid) (\(target.label ?? "?")): \(error)")
                    // D-1: drop the dead pid from the rect cache so the
                    // safety monitor doesn't keep gating mouseMoved
                    // against a stale rect.
                    await tracker?.forget(pid: target.pid)
                    continue
                }
                // D-1: refresh the rect cache for this target. The
                // safety monitor uses this to know whether mouseMoved
                // is inside a Roblox window we're cycling. The player
                // also reads this cache to translate window-relative
                // mouse coords to absolute screen coords (D-3.2).
                await tracker?.refresh(pid: target.pid)

                // D-3.2 — dispatch on sequence variant. Legacy step
                // lists still flow through the original loop body;
                // action streams hand off to ActionStreamPlayer.
                switch target.sequence.variant {
                case let .legacy(steps):
                    let outcome = await runLegacyStepLoop(
                        steps: steps,
                        target: target,
                        nextLabel: nextLabel
                    )
                    if outcome == .cancelled { return }
                case let .stream(actions):
                    let outcome = await runStreamPlayback(
                        actions: actions,
                        target: target,
                        nextLabel: nextLabel
                    )
                    if outcome == .cancelled { return }
                }
            }
            // Between iterations: tell the UI we're between targets.
            progressCallback?(nil, accounts.first?.label, nil)

            if Task.isCancelled { return }
            try? await sleeper.sleep(seconds: loopDelay)
        }
    }

    /// Hold the loop while the cycler is in `.paused`. Returns when
    /// state transitions out of paused — either auto-resume on
    /// engagement-deadline expiry, or external `resume()` / `stop()`.
    private func waitWhilePaused() async {
        while !Task.isCancelled {
            switch state {
            case .stopped:
                return
            case .running:
                return
            case .paused(.userEngaged, _):
                if let deadline = engagementDeadline {
                    let remaining = deadline.timeIntervalSinceNow
                    if remaining <= 0 {
                        // Auto-resume — engagement window cleared.
                        engagementDeadline = nil
                        updateState(.running(pids: currentPids))
                        return
                    }
                    // Poll every 250ms (or sooner if the deadline is
                    // closer). New engagement events extend `deadline`
                    // mid-poll; the loop just re-reads on the next tick.
                    let chunk = min(remaining, 0.25)
                    try? await sleeper.sleep(seconds: chunk)
                } else {
                    // No deadline set — treat as an explicit pause and
                    // poll until external resume/stop.
                    try? await sleeper.sleep(seconds: 0.25)
                }
            case .paused(.userRequested, _):
                // No deadline — wait for an external resume/stop.
                try? await sleeper.sleep(seconds: 0.25)
            case .paused(.focusStolen, _):
                // D-2: focus-theft pauses have no deadline either —
                // user must explicitly resume. Poll until state changes.
                try? await sleeper.sleep(seconds: 0.25)
            }
        }
    }

    // MARK: - Per-target playback

    /// Outcome of one target's sequence playback within the outer loop.
    /// `.completed` and `.skipped` continue to the next target;
    /// `.cancelled` returns from `runLoop` entirely.
    private enum TargetOutcome {
        case completed
        case skipped       // focus theft, target gone, etc — same-iter continue
        case cancelled     // Task.isCancelled — bail out of runLoop
    }

    /// Legacy step-list path — the ADR 0004 loop hoisted out of the
    /// outer `runLoop` so the variant dispatch above stays readable.
    /// Behavior is identical to the pre-D-3.2 inline body.
    private func runLegacyStepLoop(
        steps: [AutoKeysStep],
        target: Target,
        nextLabel: String?
    ) async -> TargetOutcome {
        stepLoop: for step in steps {
            if Task.isCancelled { return .cancelled }
            // Repeat-N support — fire the key `step.repeatCount`
            // times back-to-back, with a fixed 0.7 s gap between
            // presses (Roblox coalesces faster than that). The
            // long delay-after still applies once after the last
            // press, before moving to the next step.
            for repeatIdx in 0..<step.repeatCount {
                if Task.isCancelled { return .cancelled }
                NSLog("[RORORO] cycler: posting keyCode=\(step.keyCode) (\(repeatIdx + 1)/\(step.repeatCount)) to pid=\(target.pid)")
                progressCallback?(target.label, nextLabel, step.keyCode)
                await poster.post(keyCode: step.keyCode)
                // D-1: post-fire focus-theft check.
                let stillFront = await frontmostAppProvider.currentFrontmostPid()
                if stillFront != target.pid {
                    NSLog("[RORORO] cycler: focus moved away from pid=\(target.pid) mid-sequence (now=\(stillFront ?? -1)) — aborting remaining steps for this target")
                    break stepLoop
                }
                // Inter-press gap (only between presses; the last
                // one yields directly into delayAfter).
                if repeatIdx < step.repeatCount - 1 {
                    try? await sleeper.sleep(seconds: AutoKeysStep.intraRepeatInterval)
                }
            }
            try? await sleeper.sleep(seconds: step.delayAfter)
        }
        return .completed
    }

    /// Action-stream path (ADR 0007 / D-3.2). Builds an
    /// `ActionStreamPlayer` per target and delegates the per-action
    /// loop to it; outcome maps back to TargetOutcome for the outer
    /// loop's continuation logic.
    private func runStreamPlayback(
        actions: [AutoKeysAction],
        target: Target,
        nextLabel: String?
    ) async -> TargetOutcome {
        // The player needs a live tracker to translate window-relative
        // coords. If the cycler was constructed without one (tests that
        // skip the rect substrate), skip the target — action-stream
        // playback fundamentally needs the tracker.
        guard let tracker else {
            NSLog("[RORORO] cycler: no tracker wired; skipping action-stream target pid=\(target.pid)")
            return .skipped
        }
        progressCallback?(target.label, nextLabel, nil)
        let player = ActionStreamPlayer(
            keyPoster: poster,
            mousePoster: mousePoster,
            sleeper: sleeper,
            tracker: tracker
        )
        let provider = frontmostAppProvider
        let targetPid = target.pid
        let outcome = await player.play(
            actions: actions,
            targetPid: targetPid,
            focusGuard: { @Sendable in
                let front = await provider.currentFrontmostPid()
                return front == targetPid
            }
        )
        switch outcome {
        case .completed:
            return .completed
        case .targetGone:
            // ADR 0007 Decision 2 — drop the dead pid from the cache
            // so the safety monitor stops gating against a stale rect.
            await tracker.forget(pid: targetPid)
            return .skipped
        case .focusStolen:
            return .skipped
        case .cancelled:
            return .cancelled
        }
    }

    private func tearDown(reason: StopReason) async {
        loopTask?.cancel()
        loopTask = nil
        safetyTask?.cancel()
        safetyTask = nil
        // Don't stop the safety monitor — the view-model owns its
        // lifecycle and keeps it running so the kill-key-as-toggle
        // path can fire from `.stopped` to start the cycler again.
        assertion.release()
        // D-1: drop the rect cache. The safety monitor's mouse gating
        // defaults to "no tracked rect" when empty, restoring the
        // legacy "any mouseMoved engages" behavior between cycles.
        await tracker?.reset()
        engagementDeadline = nil
        currentPids = []
        updateState(.stopped(reason: reason))
    }

    // MARK: - State broadcast

    private func updateState(_ new: State) {
        state = new
        for continuation in stateContinuations.values {
            continuation.yield(new)
        }
    }

    private func removeContinuation(_ id: UUID) {
        stateContinuations[id] = nil
    }
}
