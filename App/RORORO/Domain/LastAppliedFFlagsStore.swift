// LastAppliedFFlagsStore.swift
// Domain — last-launch snapshot of what RobloxLauncher actually wrote to
// ClientAppSettings.json. The launcher's writer cleans the file up after
// Roblox exits (Heisenbug-avoidance vs AppleBlox's setTimeout race), so
// post-run inspection of the on-disk artifact is impossible. This store
// keeps an in-app record so DiagnosticsView can answer "what FFlags did
// the most recent launch try to apply, and which preset was folded
// in?" — without users running `find` commands.
//
// Persists via UserDefaults so the snapshot survives RORORO restarts.
// Hyperion may silently no-op individual flags at the engine layer; this
// store records what we WROTE, not what the engine ACCEPTED. For runtime
// behavior, fall back to ~/Library/Logs/Roblox/*.log + Activity Monitor
// bench (per LowResourceFFlags.swift comment).

import Foundation

@MainActor
@Observable
public final class LastAppliedFFlagsStore {

    public static let shared = LastAppliedFFlagsStore()

    public struct Snapshot: Codable, Equatable {
        public let appliedAt: Date
        /// The FFlag preset active on this launch (ADR 0011), or nil when
        /// the user launched with only their own overrides. Replaces the
        /// legacy `lowResourceMode: Bool` — a snapshot persisted before
        /// ADR 0011 decodes with activePreset == nil (the field is
        /// optional, so `decodeIfPresent` yields nil and the stale
        /// `lowResourceMode` key is simply ignored).
        public let activePreset: FFlagPresetID?
        public let flags: [String: AnyCodableValue]
        /// ClientSettingsWriter outcome string — "createdFresh" /
        /// "overwroteOurOwn" / "stompedUserEdit". Lets the user see when
        /// a hand edit got stomped or preserved.
        public let outcome: String

        public init(
            appliedAt: Date,
            activePreset: FFlagPresetID?,
            flags: [String: AnyCodableValue],
            outcome: String
        ) {
            self.appliedAt = appliedAt
            self.activePreset = activePreset
            self.flags = flags
            self.outcome = outcome
        }
    }

    public private(set) var lastSnapshot: Snapshot?

    private let defaults: UserDefaults
    private static let storageKey = "rororo.diagnostics.lastFFlagSnapshot"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? Self.decoder().decode(Snapshot.self, from: data) {
            self.lastSnapshot = decoded
        }
    }

    public func record(_ snapshot: Snapshot) {
        lastSnapshot = snapshot
        if let encoded = try? Self.encoder().encode(snapshot) {
            defaults.set(encoded, forKey: Self.storageKey)
        }
    }

    public func clear() {
        lastSnapshot = nil
        defaults.removeObject(forKey: Self.storageKey)
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
