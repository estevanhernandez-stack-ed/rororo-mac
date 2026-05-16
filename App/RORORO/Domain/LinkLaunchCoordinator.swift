// LinkLaunchCoordinator.swift
// Domain — picker state machine for inbound `roblox-player://` URLs that
// arrived without an account context. See ADR-pending: design at
// docs/launch-via-link-per-account/design.md.
//
// The coordinator suspends a caller via async continuation, exposes its
// state for SwiftUI observation, and resolves on submit (a userId),
// cancel (nil), or eviction by a newer requestChoice call (nil).

import Foundation
import Observation

@MainActor
public final class LinkLaunchCoordinator: ObservableObject {

    /// Production singleton. Tests construct fresh instances via `init()`.
    public static let shared = LinkLaunchCoordinator()

    public enum State: Equatable {
        case idle
        case choosing(pendingURL: URL, accounts: [Account])
    }

    @Published public private(set) var state: State = .idle

    private var pendingContinuation: CheckedContinuation<String?, Never>?

    public init() {}

    /// Suspend the caller until a choice is submitted, cancelled, or
    /// evicted by a newer call. Returns the chosen userId or nil.
    public func requestChoice(url: URL, accounts: [Account]) async -> String? {
        // Newest-wins eviction: if there's an in-flight continuation
        // from a prior call, resolve it with nil before starting the
        // new request. The behavior is implemented now; regression
        // coverage for the concurrent-caller scenarios lands in
        // Tasks 2 and 3 of the implementation plan.
        if let oldContinuation = pendingContinuation {
            pendingContinuation = nil
            oldContinuation.resume(returning: nil)
        }

        return await withCheckedContinuation { continuation in
            self.pendingContinuation = continuation
            self.state = .choosing(pendingURL: url, accounts: accounts)
        }
    }

    /// Resolve the in-flight continuation with the chosen userId.
    public func submit(userId: String) {
        let continuation = pendingContinuation
        pendingContinuation = nil
        state = .idle
        continuation?.resume(returning: userId)
    }

    /// Resolve the in-flight continuation with nil (user cancelled).
    public func cancel() {
        let continuation = pendingContinuation
        pendingContinuation = nil
        state = .idle
        continuation?.resume(returning: nil)
    }
}
