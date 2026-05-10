// WindowLayoutViewModel.swift
// UI-glue — bridges the toolbar Menu taps to the domain layer
// (WindowLayoutPlanner + AXWindowManager). Singleton, MainActor,
// @Observable so SwiftUI re-renders on `lastError` changes.
//
// Reads pids from RunningAccountTracker.shared. Reads cycler state
// from AutoKeysCyclerViewModel.shared so menu items can disable while
// the cycler is .running (ADR 0005 Decision 3).

import AppKit
import Foundation
import Observation

@MainActor
@Observable
public final class WindowLayoutViewModel {

    public static let shared = WindowLayoutViewModel(manager: DefaultAXWindowManager())

    private let manager: AXWindowManager

    /// Set when an apply call hits an unrecoverable error (TCC missing,
    /// or both AX writes failed for every window). Toolbar surfaces via
    /// .alert. Per-window failures DO NOT set this — they log + skip.
    public var lastError: String? = nil

    public init(manager: AXWindowManager) {
        self.manager = manager
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

        let pids = Array(RunningAccountTracker.shared.pidsByUserId.values)
        guard !pids.isEmpty else {
            lastError = "No RORORO-launched Roblox windows are running."
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
}
