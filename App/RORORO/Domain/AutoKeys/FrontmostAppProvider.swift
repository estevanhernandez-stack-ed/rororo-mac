// FrontmostAppProvider.swift
// Domain — DI seam over `NSWorkspace.frontmostApplication` for the
// auto-keys cycler's D-1 post-fire focus-theft check. Lives behind a
// protocol so test fakes can return a deterministic pid (typically the
// same pid the fake `WindowFocuser` just "focused"). Production
// conformance hops to `MainActor` since `NSWorkspace.frontmostApplication`
// is main-thread-only.

import AppKit
import Foundation

public protocol FrontmostAppProvider: Sendable {
    /// Return the currently-frontmost app's pid, or nil if there is no
    /// frontmost app (rare — typically only during early app boot).
    func currentFrontmostPid() async -> pid_t?
}

public struct NSWorkspaceFrontmostAppProvider: FrontmostAppProvider {
    public init() {}

    public func currentFrontmostPid() async -> pid_t? {
        await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
    }
}
