// FFlagPresetID.swift
// Domain — the persisted identity of a curated FFlag preset. This is what
// LaunchSettingsStore.activePreset stores; FFlagPresetLibrary maps each
// case to its FFlagPreset (display metadata + curated bundle).

import Foundation

public enum FFlagPresetID: String, Codable, CaseIterable, Sendable {
    /// Render-cost + telemetry reduction for AFK / multi-instance grinding.
    /// Backed by LowResourceFFlags.bundle (ADR 0006).
    case lowResource
    /// FPS-focused bundle — cuts the expensive render costs but less
    /// aggressively than low-resource (keeps the game watchable).
    /// Backed by PerformanceFFlags.bundle.
    case performance
}
