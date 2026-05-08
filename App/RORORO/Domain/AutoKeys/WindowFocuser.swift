// WindowFocuser.swift
// Domain — DI seam over `NSRunningApplication.activate` for the
// auto-keys cycler (Slope C). Per ADR 0004 Decision 1, the cycle walks
// each running Roblox window in turn: focus → settle → fire keys. This
// type owns the focus call + the post-focus settle; `KeyEventPoster`
// owns the keystrokes themselves.
//
// Throws `WindowFocuserError.notRunning` when the pid is no longer alive
// (account was quit mid-cycle). The cycler catches this, logs, and
// skips the account for the rest of the iteration.

import AppKit
import Foundation

public protocol WindowFocuser: Sendable {
    func focus(pid: pid_t) async throws
}

public enum WindowFocuserError: Error, Equatable {
    case notRunning(pid: pid_t)
}

public struct NSRunningApplicationFocuser: WindowFocuser {

    /// Time to wait after `activate` before treating focus as landed.
    /// Tunable; bump if Roblox is slow to settle on busy systems.
    public let settleDelay: TimeInterval

    public init(settleDelay: TimeInterval = 0.150) {
        self.settleDelay = settleDelay
    }

    public func focus(pid: pid_t) async throws {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            throw WindowFocuserError.notRunning(pid: pid)
        }
        // macOS 14+: `activate(options:)`'s option flag is deprecated and a
        // no-op. The bare `activate()` is the documented replacement; the
        // OS uses our process's activation context to decide.
        await MainActor.run {
            _ = app.activate()
        }
        try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
    }
}
