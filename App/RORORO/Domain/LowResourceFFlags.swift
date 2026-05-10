// LowResourceFFlags.swift
// Domain — curated FFlag bundle for "low-resource mode" launches.
// Goal: reduce CPU + GPU + RAM load for multi-instance / AFK-grind use
// cases where visual fidelity is irrelevant. See ADR 0006 for sources,
// rationale, and the bench-before-trust caveat.
//
// Posture:
//   - Render-only flags + telemetry. NO physics flags, NO network
//     flags, NO gameplay-affecting flags — those can break games or
//     trigger anti-cheat in some titles per Dantezz's terms.
//   - User-set fflags WIN over bundle defaults at merge time. If you
//     have a specific override (e.g. DFIntDebugFRMQualityLevelOverride=10
//     for bug-hunting), enabling Low-resource mode won't clobber it.
//   - Hyperion may silently no-op some of these. We can't verify at
//     write time; only runtime bench reveals which deltas actually land.
//     Don't trust without measurement.
//
// Sources cross-referenced:
//   - github.com/Dantezz025/Roblox-Fast-Flags (Feb 2025 update, 149 flags)
//   - github.com/AppleBlox/appleblox (ADR 0001 spike source)
//   - Bloxstrap "low-end mode" community presets

import Foundation

public enum LowResourceFFlags {

    /// The curated bundle. Merged into the user's fflag dictionary at
    /// launch time when `LaunchSettingsStore.lowResourceMode == true`.
    /// User-set fflags overlay on top of this so explicit overrides win.
    public static let bundle: [String: AnyCodableValue] = [
        // Lighting — voxel is the simplest tech (cheapest CPU/GPU). The
        // pause-voxelizer flag also disables baked-shadow updates which
        // saves additional cycles in voxel mode.
        "DFFlagDebugRenderForceTechnologyVoxel": .bool(true),
        "DFFlagDebugPauseVoxelizer":             .bool(true),

        // Render quality — force lowest preset. FRM = Frame Render Manager.
        "DFIntDebugFRMQualityLevelOverride":          .int(1),
        "FIntRomarkStartWithGraphicQualityLevel":     .int(1),

        // Post-processing — kill bloom / depth-of-field / etc.
        "FFlagDisablePostFx": .bool(true),

        // Shadows — none (highest CPU/GPU savings of any single flag).
        "FIntRenderShadowIntensity": .int(0),

        // Textures — lowest quality + no avatar texture composition.
        // Texture compositor is a notable RAM hog at default settings.
        "DFFlagTextureQualityOverrideEnabled":  .bool(true),
        "DFIntTextureQualityOverride":          .int(1),
        "DFIntTextureCompositorActiveJobs":     .int(0),

        // Grass — disable entirely. No CPU pathfinding around it,
        // no GPU draw calls, no memory for blade meshes.
        "FIntFRMMinGrassDistance":         .int(0),
        "FIntFRMMaxGrassDistance":         .int(0),
        "FIntRenderGrassDetailStrands":    .int(0),
        "FIntRenderGrassHeightScaler":     .int(0),

        // Wind — kill the global wind simulation that runs every frame.
        "FFlagGlobalWindRendering":  .bool(false),
        "FFlagGlobalWindActivated":  .bool(false),

        // Telemetry — Roblox phones home telemetry events on a CPU-side
        // background thread. Disabling cuts those bumps. Per Dantezz's
        // "Boost FPS" combination.
        "FFlagDebugDisableTelemetryEphemeralCounter":  .bool(true),
        "FFlagDebugDisableTelemetryEphemeralStat":     .bool(true),
        "FFlagDebugDisableTelemetryEventIngest":       .bool(true),
        "FFlagDebugDisableTelemetryPoint":             .bool(true),
        "FFlagDebugDisableTelemetryV2Counter":         .bool(true),
        "FFlagDebugDisableTelemetryV2Event":           .bool(true),
        "FFlagDebugDisableTelemetryV2Stat":            .bool(true),

        // Mac-specific renderer — explicit Metal preference. Already
        // the macOS default but pinning it removes an OS-side decision
        // hop on launch.
        "FFlagDebugGraphicsPreferMetal": .bool(true),
    ]

    /// Merge `bundle` into `userFlags`. User-set values WIN — they
    /// overlay on top of the bundle so explicit overrides survive
    /// enabling Low-resource mode.
    public static func merged(into userFlags: [String: AnyCodableValue]) -> [String: AnyCodableValue] {
        var out = bundle
        for (key, value) in userFlags {
            out[key] = value
        }
        return out
    }
}
