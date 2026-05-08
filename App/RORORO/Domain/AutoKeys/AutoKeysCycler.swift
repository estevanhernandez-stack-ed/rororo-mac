// AutoKeysCycler.swift
// Domain — singleton actor that owns the auto-keys loop (Slope C).
//
// State machine (per ADR 0004):
//   .stopped(reason?) ──start──▶ .running(pids) ──stop()──▶ .stopped(.userRequested)
//                                                  │
//                                                  └─cycle-budget overflow──▶ .stopped(.budgetExceeded)
//
// One full iteration walks `targets` serially: focus pid → fire each
// step's keystroke + sleep `step.delayAfter` → repeat for next target →
// then sleep `loopDelay` and re-iterate. A `WindowFocuser.notRunning`
// error skips that target for the rest of the iteration; the next
// iteration re-attempts. Before every iteration the cycler re-validates
// the snapshot through `CycleBudget` and stops itself if the cap is
// exceeded mid-flight (e.g. user added more accounts since start).
//
// For testability the actor takes its dependencies via init: a
// `KeyEventPoster`, a `WindowFocuser`, a `PowerAssertion`, and a
// `Sleeper`. `AutoKeysCycler.shared` wires the production conformances.
//
// State observability: SwiftUI binds via `observe()` → `AsyncStream<State>`.
// The toolbar (item #10) wraps the stream into an `@Observable` view-model;
// the actor itself stays UI-framework-free.

import Foundation

public actor AutoKeysCycler {

    public enum State: Equatable, Sendable {
        case stopped(reason: StopReason?)
        case running(pids: [pid_t])
    }

    public enum StopReason: Equatable, Sendable {
        case userRequested
        case budgetExceeded(estimated: TimeInterval)
        case noTargetsConfigured
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
        /// Optional human-readable label for log lines. Not load-bearing —
        /// the cycler runs identically with or without it.
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
        sleeper: TaskSleeper()
    )

    private let poster: KeyEventPoster
    private let focuser: WindowFocuser
    private let assertion: PowerAssertion
    private let sleeper: Sleeper

    public private(set) var state: State = .stopped(reason: nil)
    private var loopTask: Task<Void, Never>?
    private var stateContinuations: [UUID: AsyncStream<State>.Continuation] = [:]

    public init(
        poster: KeyEventPoster,
        focuser: WindowFocuser,
        assertion: PowerAssertion,
        sleeper: Sleeper
    ) {
        self.poster = poster
        self.focuser = focuser
        self.assertion = assertion
        self.sleeper = sleeper
    }

    // MARK: - Public API

    /// Begin cycling over `accounts`. Refuses to start if the estimated
    /// cycle time exceeds `CycleBudget.hardCap` — caller must prune
    /// sequences first. Restarts cleanly if already running.
    public func start(accounts: [Target], loopDelay: TimeInterval) async throws {
        // Restart pattern — if we're already running, stop first so the
        // wake-lock + loop task lifecycle stays clean.
        if loopTask != nil {
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

        // Empty / all-empty target list: surface a discrete stop reason
        // so the toolbar can show "no accounts configured" instead of
        // a generic ".stopped".
        let active = accounts.filter { !$0.sequence.isEmpty }
        guard !active.isEmpty else {
            updateState(.stopped(reason: .noTargetsConfigured))
            return
        }

        try assertion.acquire(reason: "RORORO auto-keys cycler running")
        let pids = active.map(\.pid)
        updateState(.running(pids: pids))

        loopTask = Task { [weak self] in
            await self?.runLoop(accounts: active, loopDelay: loopDelay)
        }
    }

    /// Stop the cycler — cancels the loop task, releases the wake-lock,
    /// transitions to `.stopped(.userRequested)`. No-op if already
    /// stopped. Safe to call from any actor context.
    public func stop() async {
        await tearDown(reason: .userRequested)
    }

    /// Subscribe to state transitions. The first yield is the current
    /// state at subscription time; subsequent yields fire on every
    /// transition. Termination of the consumer task auto-removes the
    /// continuation (no leaks).
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

    // MARK: - Internal loop

    private func runLoop(accounts: [Target], loopDelay: TimeInterval) async {
        while !Task.isCancelled {
            // Re-validate budget. If the user reconfigured sequences mid-
            // flight to exceed the cap, bail out cleanly.
            let snapshot = accounts.map(\.sequence)
            let estimate = CycleBudget.estimate(snapshot: snapshot, loopDelay: loopDelay)
            if CycleBudget.state(for: estimate) == .overCap {
                await tearDown(reason: .budgetExceeded(estimated: estimate))
                return
            }

            for target in accounts {
                if Task.isCancelled { return }
                if target.sequence.isEmpty { continue }
                do {
                    try await focuser.focus(pid: target.pid)
                } catch {
                    // Window for this pid is gone (account was quit
                    // mid-cycle). Log and skip — re-evaluated next
                    // iteration. Other targets in the same iteration
                    // continue normally.
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

    private func tearDown(reason: StopReason) async {
        loopTask?.cancel()
        loopTask = nil
        assertion.release()
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
