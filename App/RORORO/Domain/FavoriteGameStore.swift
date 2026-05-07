// FavoriteGameStore.swift
// Domain — persisted default-game URL for the `.defaultGame` LaunchTarget
// resolver. v0.1.0: a single URL, persisted to UserDefaults.
//
// v0.2.0+ may grow this into a proper favorites list (multiple games per
// account, per-game defaults, etc.) — the API surface stays
// backwards-compatible because callers only ask for `defaultGameURL`.

import Foundation
import Observation

@MainActor
@Observable
public final class FavoriteGameStore {

    public static let shared = FavoriteGameStore()

    public static let defaultGameURLKey = "RORORO.defaultGameURL"

    public var defaultGameURL: String {
        didSet { UserDefaults.standard.set(defaultGameURL, forKey: Self.defaultGameURLKey) }
    }

    private init() {
        self.defaultGameURL = UserDefaults.standard.string(forKey: Self.defaultGameURLKey) ?? ""
    }
}
