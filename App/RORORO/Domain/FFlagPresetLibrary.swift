// FFlagPresetLibrary.swift
// Domain — the registry of curated FFlag presets, plus the single
// launch-time merge point (effectiveFlags). The FFlags sheet reads `all`
// to render preset cards; RobloxLauncher calls `effectiveFlags` to build
// the dictionary it hands to ClientSettingsWriter.

import Foundation

public enum FFlagPresetLibrary {

    /// Every curated preset, in display order. The FFlags sheet renders
    /// one card per entry (plus a "None" card it synthesizes itself).
    public static let all: [FFlagPreset] = [
        FFlagPreset(
            id: .lowResource,
            displayName: "Low-resource",
            summary: "AFK / multi-instance grind",
            bundle: LowResourceFFlags.bundle
        ),
        FFlagPreset(
            id: .performance,
            displayName: "Performance",
            summary: "FPS boost, still watchable",
            bundle: PerformanceFFlags.bundle
        ),
    ]

    /// Look up a preset by its persisted ID. Returns nil if the ID has no
    /// registered preset (shouldn't happen — FFlagPresetID is exhaustive —
    /// but callers degrade to "no preset" rather than crashing).
    public static func preset(_ id: FFlagPresetID) -> FFlagPreset? {
        all.first { $0.id == id }
    }

    /// The launch-time merge point. Resolves the active preset's bundle
    /// (empty when `activePreset` is nil) and overlays the user's override
    /// dictionary on top — user value WINS on key collision, exactly the
    /// semantics LowResourceFFlags.merged(into:) had before generalization.
    public static func effectiveFlags(
        for activePreset: FFlagPresetID?,
        userOverrides: [String: AnyCodableValue]
    ) -> [String: AnyCodableValue] {
        let base = activePreset.flatMap { preset($0)?.bundle } ?? [:]
        return base.merging(userOverrides) { _, userValue in userValue }
    }
}
