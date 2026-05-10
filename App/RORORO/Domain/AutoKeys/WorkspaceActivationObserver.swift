// WorkspaceActivationObserver.swift
// Domain — DI seam over `NSWorkspace.didActivateApplicationNotification`
// for the auto-keys safety monitor's D-2 focus-theft detector. Lives
// behind a protocol so test fakes can fire synthetic "app activated"
// events without going through AppKit's notification machinery.
//
// Production wires `NSWorkspaceActivationObserver`; tests inject
// `FakeWorkspaceActivationObserver` and call `fire(pid:)` to drive the
// safety monitor's handler.
//
// Pattern matches `MultiInstanceCoordinator.swift`'s use of
// `NSWorkspace.shared.notificationCenter` — same notification surface,
// different event name (didActivate vs didTerminate).

import AppKit
import Foundation

public protocol WorkspaceActivationObserver: Sendable {
    /// Subscribe to "app became frontmost" events. The handler is
    /// called with the activated pid each time a different app comes
    /// to the front. Returns a token that, when cancelled (or dropped),
    /// removes the observer.
    func observe(_ handler: @escaping @Sendable (pid_t) -> Void) -> WorkspaceActivationCancellable
}

/// RAII-ish handle returned by `observe`. Cancellation removes the
/// underlying notification observer. Cancelled automatically on deinit.
public final class WorkspaceActivationCancellable: @unchecked Sendable {
    private let lock = NSLock()
    private var cleanup: (() -> Void)?

    public init(cleanup: @escaping () -> Void) {
        self.cleanup = cleanup
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cleanup?()
        cleanup = nil
    }

    deinit {
        cancel()
    }
}

public struct NSWorkspaceActivationObserver: WorkspaceActivationObserver {
    public init() {}

    public func observe(_ handler: @escaping @Sendable (pid_t) -> Void) -> WorkspaceActivationCancellable {
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            handler(app.processIdentifier)
        }
        return WorkspaceActivationCancellable {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }
}
