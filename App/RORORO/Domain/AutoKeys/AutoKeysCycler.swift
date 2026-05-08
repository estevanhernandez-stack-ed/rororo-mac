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
        focuser: NSRunningApplicationFocuser(),
        assertion: IOPMPowerAssertion(),
        sleeper: TaskSleeper(),
        safety: AutoKeysSafetyMonitor(tapping: NSEventTapping())
    )

    private let poster: KeyEventPoster
    private let focuser: WindowFocuser
    private let assertion: PowerAssertion
    private let sleeper: Sleeper
    /// Optional — production wires the real monitor; tests can pass nil
    /// to skip safety integration entirely, OR pass a fake monitor with
    /// a fake `EventTapping` to drive engagement / kill events.
    private let safety: AutoKeysSafetyMonitor?

    public private(set) var state: State = .stopped(reason: nil)
    private var loopTask: Task<Void, Never>?
    private var safetyTask: Task<Void, Never>?
    private var stateContinuations: [UUID: AsyncStream<State>.Continuation] = [:]

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
        focuser: WindowFocuser,
        assertion: PowerAssertion,
        sleeper: Sleeper,
        safety: AutoKeysSafetyMonitor? = nil
    ) {
        self.poster = poster
        self.focuser = focuser
        self.assertion = assertion
        self.sleeper = sleeper
        self.safety = safety
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
        updateState(.running(pids: pids))

        // Subscribe to safety events BEFORE the loop spawns so the very
        // first engagement event we'd care about doesn't slip past us.
        if let safety {
            await safety.start()
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
    /// the wake-lock, transitions to `.stopped(.userRequested)`.
    public func stop() async {
        await tearDown(reason: .userRequested)
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
            // Only meaningful while we're in a state the user can pause
            // out of (.running or extending an existing engagement pause).
            // Explicit user pauses (.userRequested) and stopped states
            // ignore engagement events.
            switch state {
            case .running, .paused(.userEngaged, _):
                let deadline = Date().addingTimeInterval(resumeGrace)
                engagementDeadline = deadline
                updateState(.paused(reason: .userEngaged, until: deadline))
            case .stopped, .paused(.userRequested, _):
                return
            }

        case .killRequested:
            await tearDown(reason: .userKilled)
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

            for target in accounts {
                if Task.isCancelled { return }
                await waitWhilePaused()
                if Task.isCancelled { return }
                if target.sequence.isEmpty { continue }
                do {
                    try await focuser.focus(pid: target.pid)
                } catch {
                    NSLog("[RORORO] auto-keys: skipping pid=\(target.pid) (\(target.label ?? "?")): \(error)")
                    continue
                }
                for step in target.sequence.steps {
                    if Task.isCancelled { return }
                    await poster.post(keyCode: step.keyCode)
                    try? await sleeper.sleep(seconds: step.delayAfter)
                }
            }

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
            }
        }
    }

    private func tearDown(reason: StopReason) async {
        loopTask?.cancel()
        loopTask = nil
        safetyTask?.cancel()
        safetyTask = nil
        if let safety {
            await safety.stop()
        }
        assertion.release()
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
