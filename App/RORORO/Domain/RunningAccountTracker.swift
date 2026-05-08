// RunningAccountTracker.swift
// Domain — observable bridge between "this Roblox process exists with
// pid X" and "this saved account is currently running" (Slope C wave 3).
//
// Why this exists: the cycler's per-account `AutoKeysSequence` only
// makes sense if we know which running Roblox window belongs to which
// account. `MultiInstanceCoordinator.handleIncomingURL` is the only
// place we have both pieces of information at the same time — the
// account's userId from the launch request + the spawned Roblox's pid
// from `waitForLaunchToSettle`. This tracker lives downstream of that
// junction and exposes the mapping for the cycler view-model to read
// at Play time.
//
// Lifecycle:
//   - register(pid:userId:) called from MultiInstanceCoordinator after
//     the new Roblox process settles (NSRunningApplication has
//     `isFinishedLaunching == true`).
//   - unregister(pid:) called from MultiInstanceCoordinator's
//     handleAppDidTerminate observer when the Roblox process exits.
//
// The mapping is one-userId-to-one-pid. If the same account is launched
// twice (rare; usually accounts have unique sequences), the second
// register replaces the first — the older pid is dropped. The cycler
// re-snapshots at Play time so a stale entry only matters if the user
// presses Play during the brief window between launches.

import Foundation
import Observation

@MainActor
@Observable
public final class RunningAccountTracker {

    public static let shared = RunningAccountTracker()

    /// userId → pid_t for currently-running Roblox processes the launcher
    /// spawned. Read by the cycler view-model when building `[Target]`.
    public private(set) var pidsByUserId: [String: pid_t] = [:]

    private init() {}

    public func register(pid: pid_t, userId: String) {
        pidsByUserId[userId] = pid
    }

    public func unregister(pid: pid_t) {
        pidsByUserId = pidsByUserId.filter { $0.value != pid }
    }

    public func unregister(userId: String) {
        pidsByUserId.removeValue(forKey: userId)
    }

    /// Drop everything — used by tests and by the multi-instance reset
    /// path (e.g. user toggled multi-instance off; existing registrations
    /// stay accurate, but `clear()` is here for manual reset).
    public func clear() {
        pidsByUserId.removeAll()
    }

    public func pid(for userId: String) -> pid_t? {
        pidsByUserId[userId]
    }

    /// Currently-running userIds, sorted alphabetically for stable UI.
    public func runningUserIds() -> [String] {
        pidsByUserId.keys.sorted()
    }
}
