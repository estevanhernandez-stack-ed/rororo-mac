// RunningAccountTracker.swift
// Domain — observable bridge between "this Roblox process exists with
// pid X" and "this saved account is currently running" (Slope C wave 3).
//
// Two paths to fill the map:
//   - Live registration via MultiInstanceCoordinator after the launcher
//     spawns a new Roblox process and `waitForLaunchToSettle` returns
//     a pid. This is the strict / authoritative path.
//   - Best-effort `backfillFromRunningProcesses()` — scans NSWorkspace
//     for running Roblox bundles and matches them to AccountStore
//     accounts by `localizedName` (which equals the per-instance
//     bundle's `CFBundleName`, set by RobloxAppCopier to the account
//     display label). Lets the cycler pick up Roblox windows the
//     current RORORO process didn't launch (e.g. user relaunched the
//     dev build mid-session).
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

import AppKit
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

    /// Best-effort: walk `NSWorkspace.runningApplications` for Roblox
    /// bundles and match each to a saved account by bundle URL basename.
    ///
    /// The per-instance bundle on disk is named `{sanitizedLabel}.app`
    /// where `label = account.displayName`. We match on the bundle's
    /// filesystem path basename rather than `localizedName`, because
    /// `localizedName` falls back to the original `CFBundleName`
    /// (`"Roblox"`) when CFBundleDisplayName isn't set on the copy —
    /// which is the actual case here. Bundle path is deterministic.
    ///
    /// Already-tracked pids are skipped; new matches register. Returns
    /// the count of new matches.
    @discardableResult
    public func backfillFromRunningProcesses() -> Int {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier?.hasPrefix("com.roblox") == true }
        let accounts = AccountStore.shared.accounts
        var added = 0
        NSLog("[RORORO] backfill: scanning \(running.count) running Roblox processes against \(accounts.count) accounts")
        for app in running {
            // Skip if this pid is already tracked (under any userId).
            if pidsByUserId.values.contains(app.processIdentifier) { continue }
            guard let bundleURL = app.bundleURL else { continue }
            let basename = bundleURL.deletingPathExtension().lastPathComponent
            NSLog("[RORORO] backfill: pid=\(app.processIdentifier) bundle=\(basename) localizedName=\(app.localizedName ?? "?")")
            // Match basename → sanitized(displayName). The launcher
            // names the bundle via `RobloxAppCopier.sanitizedBundleLabel`
            // so we run the same sanitizer here for an exact compare.
            if let account = accounts.first(where: {
                RobloxAppCopier.sanitizedBundleLabel(from: $0.displayName) == basename
            }) {
                pidsByUserId[account.userId] = app.processIdentifier
                added += 1
                NSLog("[RORORO] backfill: matched pid=\(app.processIdentifier) → userId=\(account.userId) (\(account.displayName))")
            } else {
                NSLog("[RORORO] backfill: no account match for bundle=\(basename)")
            }
        }
        NSLog("[RORORO] backfill: \(added) new mapping(s) added; tracker now has \(pidsByUserId.count) entries")
        return added
    }
}
