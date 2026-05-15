// PerformanceFFlags.swift
// Domain — curated FFlag bundle for "performance mode" launches: an FPS
// win that keeps the game watchable. Lighter than LowResourceFFlags —
// it kills pure overhead (telemetry, wind) and the cheapest big render
// cost (post-FX), tames grass, and pins Metal, but leaves lighting,
// shadows, and textures at the game's own quality settings.
//
// Posture (mirrors ADR 0006):
//   - Render-only flags + telemetry. NO physics / network / simulation
//     flags — those can break games or trip anti-cheat in some titles.
//   - Hyperion may silently no-op some of these; only a runtime bench
//     reveals which deltas actually land. Ships untested — see ADR 0011.
//
// Sources cross-referenced (same as ADR 0006):
//   - github.com/Dantezz025/Roblox-Fast-Flags
//   - github.com/AppleBlox/appleblox
//   - Bloxstrap community "FPS boost" presets

import Foundation

public enum PerformanceFFlags {

    /// The curated bundle. Merged with the user's overrides at launch via
    /// FFlagPresetLibrary.effectiveFlags — user-set fflags win on overlap.
    public static let bundle: [String: AnyCodableValue] = [
        // Post-processing — bloom / DoF / motion blur are the cheapest
        // big FPS win; the game stays fully readable without them.
        "FFlagDisablePostFx": .bool(true),

        // Wind — the global wind sim runs every frame for a subtle
        // effect. Pure overhead for an FPS-focused profile.
        "FFlagGlobalWindRendering": .bool(false),
        "FFlagGlobalWindActivated": .bool(false),

        // Grass — keep it, but cap detail + draw distance. Visible
        // nearby, not paid for across the whole map.
        "FIntFRMMaxGrassDistance":      .int(40),
        "FIntRenderGrassDetailStrands": .int(0),

        // Telemetry — Roblox's analytics back-channel runs on a CPU-side
        // thread. Disabling it is a pure win with zero visual cost.
        "FFlagDebugDisableTelemetryEphemeralCounter": .bool(true),
        "FFlagDebugDisableTelemetryEphemeralStat":    .bool(true),
        "FFlagDebugDisableTelemetryEventIngest":      .bool(true),
        "FFlagDebugDisableTelemetryPoint":            .bool(true),
        "FFlagDebugDisableTelemetryV2Counter":        .bool(true),
        "FFlagDebugDisableTelemetryV2Event":          .bool(true),
        "FFlagDebugDisableTelemetryV2Stat":           .bool(true),

        // Mac renderer — pin Metal explicitly (already the macOS default;
        // pinning removes an OS-side decision hop at launch).
        "FFlagDebugGraphicsPreferMetal": .bool(true),
    ]
}
