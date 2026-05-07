// MultiInstanceState.swift
// Domain — observable UI state for the multi-instance coordinator.
//
// Lives on the main actor; views read it via `@Bindable` / `@Environment`
// in Phase 5. The coordinator hops to MainActor.run when updating these
// properties from its background work.
//
// `enabled` persists to UserDefaults so the user's last toggle survives
// app relaunch. `instanceCount` and `lastError` are session-scoped.

import Foundation
import Observation

@MainActor
@Observable
public final class MultiInstanceState {

    public static let shared = MultiInstanceState()

    /// User-facing toggle. When OFF, RORORO still routes `roblox-player://`
    /// URLs (because we own the scheme) but skips the copy-and-break recipe
    /// — the URL goes straight to `/Applications/Roblox.app` for a normal,
    /// single-instance launch. When ON, every launch gets a fresh instance.
    public var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }

    /// Most recent failure surfaced by the coordinator. UI clears this on
    /// the next successful launch. nil when nothing has gone wrong.
    public var lastError: String?

    /// Successful multi-instance launches since the app started. Used by
    /// the tray status ring + diagnostics view.
    public var instanceCount: Int = 0

    public static let enabledKey = "RORORO.MultiInstance.enabled"

    private init() {
        let defaults = UserDefaults.standard
        // First run defaults to ON — that's why the user installed RORORO.
        // If the key is absent, register the default; subsequent reads
        // honor whatever the user set.
        if defaults.object(forKey: Self.enabledKey) == nil {
            defaults.set(true, forKey: Self.enabledKey)
        }
        self.enabled = defaults.bool(forKey: Self.enabledKey)
    }
}
