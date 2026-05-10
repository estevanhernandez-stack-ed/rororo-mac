// WindowLayoutViewModel.swift
// UI-glue — bridges the toolbar Menu taps to the domain layer
// (WindowLayoutPlanner + AXWindowManager). Singleton, MainActor,
// @Observable so SwiftUI re-renders on `lastError` changes.
//
// Reads pids from RunningAccountTracker.shared. Reads cycler state
// from AutoKeysCyclerViewModel.shared so menu items can disable while
// the cycler is .running (ADR 0005 Decision 3).
//
// P1.5: includeExternalWindows toggle augments the pid set with any
// running com.roblox.* process not tracked by RORORO. External windows
// participate in tile/shrink only — they don't get accounts, auto-keys,
// or relogin. Demand-driven addition (ADR 0005 Decision 1 Consequences:
// "If demand surfaces for tile-all-Roblox-windows, we add a toggle").

import AppKit
import Foundation
import Observation

@MainActor
@Observable
public final class WindowLayoutViewModel {

    public static let shared = WindowLayoutViewModel(manager: DefaultAXWindowManager())

    private let manager: AXWindowManager

    private static let includeExternalKey = "rororo.windowLayout.includeExternalWindows"

    /// Set when an apply call hits an unrecoverable error (TCC missing,
    /// or both AX writes failed for every window). Toolbar surfaces via
    /// .alert. Per-window failures DO NOT set this — they log + skip.
    public var lastError: String? = nil

    /// When true, the layout actions augment RORORO-tracked pids with
    /// any running com.roblox.* processes not launched by RORORO.
    /// External windows get tile/shrink only — never accounts/auto-keys.
    /// Persisted in UserDefaults; survives relaunch.
    public var includeExternalWindows: Bool {
        didSet {
            UserDefaults.standard.set(includeExternalWindows, forKey: Self.includeExternalKey)
        }
    }

    public init(manager: AXWindowManager) {
        self.manager = manager
        self.includeExternalWindows = UserDefaults.standard.bool(forKey: Self.includeExternalKey)
    }

    public func clearError() {
        lastError = nil
    }

    // MARK: - public actions

    public func applyAutoGrid() async {
        await apply(mode: .autoGrid)
    }

    public func applyGrid(cols: Int, rows: Int) async {
        await apply(mode: .grid(cols: cols, rows: rows))
    }

    public func applyShrink(percent: Double) async {
        await apply(mode: .shrink(percent: percent))
    }

    // MARK: - private

    private func apply(mode: LayoutMode) async {
        // Defense-in-depth: UI also disables the menu items, but if the
        // VM is invoked some other way we still bail.
        if case .running = AutoKeysCyclerViewModel.shared.state {
            lastError = "Stop auto-keys before rearranging windows."
            return
        }

        let internalPids = Array(RunningAccountTracker.shared.pidsByUserId.values)
        let externalPids = includeExternalWindows
            ? Self.enumerateExternalRobloxPids(excluding: Set(internalPids))
            : []
        let pids = internalPids + externalPids
        guard !pids.isEmpty else {
            lastError = includeExternalWindows
                ? "No Roblox windows are running."
                : "No RORORO-launched Roblox windows are running. Toggle 'Include external windows' in the Layout menu to tile externally-launched ones too."
            return
        }

        let visibleRect = currentVisibleRect()

        // Read current frames only when needed (shrink). For grid modes
        // we don't need them — saves one AX round-trip per pid.
        var currentFrames: [pid_t: CGRect] = [:]
        if case .shrink = mode {
            for pid in pids {
                if let frame = try? await manager.mainWindowFrame(pid: pid) {
                    currentFrames[pid] = frame
                }
            }
        }

        let plan = WindowLayoutPlanner.plan(
            mode: mode,
            pids: pids,
            visibleRect: visibleRect,
            currentFrames: currentFrames
        )

        var anySucceeded = false
        for (pid, frame) in plan {
            do {
                try await manager.resize(pid: pid, to: frame)
                anySucceeded = true
            } catch {
                NSLog("[RORORO] layout: pid=\(pid) resize threw \(error)")
                // Continue — per-window failures are fail-soft.
            }
        }

        if !anySucceeded {
            lastError = "No windows were rearranged. Accessibility permission may be missing — open System Settings → Privacy & Security → Accessibility and grant RORORO."
        }
    }

    private func currentVisibleRect() -> CGRect {
        if let screen = NSApp.mainWindow?.screen {
            return screen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? .zero
    }

    /// Enumerate running com.roblox.* processes whose pids are NOT in
    /// `excluding` (the RORORO-tracked set). These are externally-launched
    /// Roblox windows — e.g. the user's pre-existing grinding session.
    /// Same bundle-id prefix convention used by MultiInstanceCoordinator
    /// + RunningAccountTracker.
    private static func enumerateExternalRobloxPids(excluding: Set<pid_t>) -> [pid_t] {
        NSWorkspace.shared.runningApplications
            .filter { app in
                guard let bid = app.bundleIdentifier else { return false }
                return bid.hasPrefix("com.roblox") && !excluding.contains(app.processIdentifier)
            }
            .map(\.processIdentifier)
    }
}
