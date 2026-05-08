// AutoKeysCyclerViewModel.swift
// Domain (UI-glue) — `@MainActor @Observable` bridge between the
// `AutoKeysCycler` actor and SwiftUI (Slope C wave 3). The cycler's
// `state` and `observe()` AsyncStream live behind actor isolation;
// SwiftUI binds to plain stored properties. The view-model subscribes
// to the stream once, republishes the latest state to the main actor,
// and exposes plain methods (`play()`, `pause()`, `resume()`, `stop()`)
// the toolbar + banner views can call.
//
// Building `[Target]` at play time:
//   1. Walk `AccountStore.shared.accounts` for entries with non-nil,
//      non-empty `autoKeys`.
//   2. Look up each one's pid in `RunningAccountTracker.shared` —
//      accounts that aren't currently running are skipped.
//   3. The result feeds `cycler.start(accounts:loopDelay:)`.

import Foundation
import Observation

@MainActor
@Observable
public final class AutoKeysCyclerViewModel {

    public static let shared = AutoKeysCyclerViewModel()

    /// Latest cycler state, mirrored from the actor. UI binds to this.
    public private(set) var state: AutoKeysCycler.State = .stopped(reason: nil)
    /// Latest estimated cycle time over the snapshot the toolbar built —
    /// recomputed on every `refreshEstimate()` call. Tied to the
    /// CycleBudget warn/cap thresholds for color-coded label rendering.
    public private(set) var lastEstimate: TimeInterval = 0
    /// Banner string when permissions are missing or no accounts are
    /// configured. Surfaced in the toolbar / recorder; nil = no issue.
    public private(set) var preflightMessage: String?
    /// Last error from a `play()` attempt — used for an alert / banner.
    public private(set) var lastError: String?

    private let cycler: AutoKeysCycler
    private let store: AccountStore
    private let tracker: RunningAccountTracker
    private let settings: LaunchSettingsStore
    private var observerTask: Task<Void, Never>?

    private init() {
        self.cycler = .shared
        self.store = .shared
        self.tracker = .shared
        self.settings = .shared
        startObserving()
    }

    /// Test seam — production callers use `.shared`.
    init(
        cycler: AutoKeysCycler,
        store: AccountStore,
        tracker: RunningAccountTracker,
        settings: LaunchSettingsStore
    ) {
        self.cycler = cycler
        self.store = store
        self.tracker = tracker
        self.settings = settings
        startObserving()
    }

    // No deinit — `.shared` is process-lifetime; the test-seam initializer
    // also holds the task for the test's duration. Cancellation isn't a
    // concern here since the cycler's `observe()` stream cleans up
    // continuations on its own when consumers disappear.

    // MARK: - Public API

    /// Build a snapshot from configured + currently-running accounts and
    /// hand it to the cycler. Surfaces permission / no-target errors via
    /// `preflightMessage` rather than throwing.
    public func play() async {
        preflightMessage = nil
        lastError = nil

        // Permission preflight. Both Accessibility (for posting) and
        // Input Monitoring (for the safety monitor) must be granted.
        if AutoKeysPermissions.accessibilityStatus() != .granted {
            preflightMessage = "Auto-keys needs Accessibility permission to send keystrokes. Open System Settings → Privacy & Security → Accessibility, then press Play again."
            return
        }
        if AutoKeysPermissions.inputMonitoringStatus() != .granted {
            preflightMessage = "Auto-keys needs Input Monitoring to detect the kill key + pause when you move the mouse. Open System Settings → Privacy & Security → Input Monitoring, then press Play again."
            return
        }

        let targets = buildTargets()
        guard !targets.isEmpty else {
            preflightMessage = "No accounts are configured for auto-keys. Configure at least one account's keystroke sequence first."
            return
        }

        let loopDelay = settings.autoKeysLoopDelay
        let snapshot = targets.map(\.sequence)
        let estimate = CycleBudget.estimate(snapshot: snapshot, loopDelay: loopDelay)
        lastEstimate = estimate

        do {
            try await cycler.start(accounts: targets, loopDelay: loopDelay)
        } catch let AutoKeysCycler.StartError.budgetExceeded(estimated, hardCap) {
            lastError = "Cycle estimate is \(formatSeconds(estimated)) — over the \(formatSeconds(hardCap)) hard cap. Trim sequences or run fewer accounts."
        } catch {
            lastError = "Couldn't start auto-keys: \(error.localizedDescription)"
        }
    }

    public func pause() async {
        await cycler.pause()
    }

    public func resume() async {
        await cycler.resume()
    }

    public func stop() async {
        await cycler.stop()
    }

    /// Recompute the cycle-time estimate from the live snapshot. Cheap;
    /// the toolbar calls this when accounts list mutates so the label
    /// reflects warn / overCap state without waiting for Play.
    public func refreshEstimate() {
        let targets = buildTargets()
        let snapshot = targets.map(\.sequence)
        lastEstimate = CycleBudget.estimate(
            snapshot: snapshot,
            loopDelay: settings.autoKeysLoopDelay
        )
    }

    // MARK: - Helpers

    private func buildTargets() -> [AutoKeysCycler.Target] {
        store.accounts.compactMap { account in
            guard let sequence = account.autoKeys, !sequence.isEmpty else { return nil }
            guard let pid = tracker.pid(for: account.userId) else { return nil }
            return AutoKeysCycler.Target(
                pid: pid,
                sequence: sequence,
                label: account.displayName
            )
        }
    }

    private func startObserving() {
        observerTask = Task { [weak self] in
            guard let stream = await self?.cycler.observe() else { return }
            for await new in stream {
                if Task.isCancelled { return }
                await MainActor.run {
                    self?.state = new
                }
            }
        }
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        } else {
            return "\(secs)s"
        }
    }
}
