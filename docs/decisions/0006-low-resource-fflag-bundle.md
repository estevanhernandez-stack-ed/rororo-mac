# ADR 0006 — Low-resource FFlag bundle

**Date:** 2026-05-10
**Status:** Accepted (untested at runtime — requires bench)
**Slope:** A (FFlag injection, builds on ADR 0001 Decision 2)
**Spike:** github.com/Dantezz025/Roblox-Fast-Flags (Feb 2025, 149 flags) — primary source. Cross-referenced against AppleBlox (ADR 0001 spike) and Bloxstrap conventions.

## Background

The window-layout investigation (ADR 0005) surfaced that Roblox's macOS player enforces a hardcoded ~800×600 window minimum. After retracting Shrink, attention pivoted to throughput — for users running multiple Roblox instances for AFK / grinding workloads, CPU and RAM pressure are the bottleneck. Visual fidelity is irrelevant when the window is being driven by an auto-keys cycler and the user isn't watching the avatar.

ADR 0001 Decision 2 already proves the FFlag injection surface: `ClientSettingsWriter` writes a JSON dictionary to `<RobloxBundle>/Contents/MacOS/ClientSettings/ClientAppSettings.json` at launch time. The writer is generic; what we lacked was a curated bundle of FFlags known to reduce CPU + GPU + RAM load on Mac multi-instance workloads.

## Decision 1 — Bundle posture: render-only + telemetry; no physics, no network

**Decision:** The `LowResourceFFlags.bundle` constant only contains flags that affect rendering pipeline (lighting, shadows, textures, post-FX, grass, wind) and telemetry (Roblox's analytics back-channel). It deliberately excludes physics flags, network flags, and gameplay-affecting flags.

**Rationale:** Dantezz's repo flags two warnings: *"Some Fast Flags Can Be Banable In Certain Games"* and *"Use it on your own risk."* Physics and network flags are the high-risk category — they can break gameplay in ways anti-cheat systems detect (e.g., physics-time tweaks that look like exploits, network-tick changes that desync). Render and telemetry flags are visual + observability concerns; even a maximally-aggressive render reduction is just "the game looks cheap" not "the player has unfair physics."

**Consequences:** The bundle is conservative by design. We trade some achievable performance gains (e.g., simulation-radius tweaks) for a much lower risk surface. Users who want more aggressive flag bundles can layer them on top via the existing `LaunchSettingsStore.fflags` user-set entries — those overlay on top of the bundle (Decision 3).

## Decision 2 — The bundle (curated 2026-05-10)

**Decision:** The shipped bundle is documented in `App/RORORO/Domain/LowResourceFFlags.swift`. Twenty-five flags grouped into seven logical clusters:

| Cluster | Flags | What it does |
|---|---|---|
| **Lighting** | `DFFlagDebugRenderForceTechnologyVoxel=true`, `DFFlagDebugPauseVoxelizer=true` | Force voxel lighting (cheapest tech); disable baked shadow updates |
| **Render quality** | `DFIntDebugFRMQualityLevelOverride=1`, `FIntRomarkStartWithGraphicQualityLevel=1` | Lowest preset quality |
| **Post-FX** | `FFlagDisablePostFx=true` | Kill bloom/DoF/motion blur |
| **Shadows** | `FIntRenderShadowIntensity=0` | None |
| **Textures** | `DFFlagTextureQualityOverrideEnabled=true`, `DFIntTextureQualityOverride=1`, `DFIntTextureCompositorActiveJobs=0` | Lowest texture quality + no avatar texture composition (notable RAM saving) |
| **Grass** | `FIntFRMMin/MaxGrassDistance=0`, `FIntRenderGrassDetailStrands=0`, `FIntRenderGrassHeightScaler=0` | None |
| **Wind** | `FFlagGlobalWindRendering=false`, `FFlagGlobalWindActivated=false` | Disable global wind sim |
| **Telemetry** | 7 `FFlagDebugDisableTelemetry*` flags | Disable Roblox's analytics back-channel |
| **Mac renderer** | `FFlagDebugGraphicsPreferMetal=true` | Pin Metal explicitly (already default) |

**Rationale:** Each flag was cross-referenced against Dantezz's "Absolutely kills your game graphics" combination + their "Boost FPS" combination + AppleBlox's render-degrade preset. Flags that appeared in at least two sources made the cut. Flags from only one source were excluded as low-confidence.

**Consequences:** The bundle is intentionally larger than a minimal "just turn off shadows" set. The reasoning: Roblox's render pipeline has multiple parallel cost centers (lighting, post-FX, shadows, textures, terrain features). Killing one reveals the next as the bottleneck. The bundle attacks all major centers so the multi-instance use case sees compounding gains, not just a 5–10% per-instance reduction that gets eaten by the next bottleneck.

## Decision 3 — User overrides win on overlap

**Decision:** `LowResourceFFlags.merged(into:)` overlays the user's `LaunchSettingsStore.fflags` on top of the bundle. If the user explicitly sets `DFIntDebugFRMQualityLevelOverride=10` for some bug-hunting reason, that value wins even with Low-resource mode ON.

**Rationale:** The Low-resource toggle is a coarse default. Users who've set specific FFlags through the existing store have done so deliberately — clobbering their explicit choices when they enable a coarse mode would surprise them. The merge order encodes "your explicit choice always wins; the bundle is just the floor."

**Consequences:** `LaunchSettingsStore.fflags` retains its existing semantics (no behavioral change for users who don't touch Low-resource mode). Users who want pure-bundle behavior simply leave their fflags dict empty. Tested via `testMerge_UserFlagOverridesBundle_UserWins`.

## Decision 4 — Hyperion: assume some flags are silently no-op'd; bench, don't trust

**Decision:** The shipped UI explicitly tells the user: *"Hyperion may silently no-op some — bench actual deltas before trusting."* No claim is made about which specific flags survive Hyperion's allowlist; that's a runtime question.

**Rationale:** ADR 0001 Decision 1 documented that Hyperion locks the FFlag write surface for many flags — `DFIntTaskSchedulerTargetFps` and the framerate flags specifically were observed locked. We don't know which of the 25 flags in Decision 2 are also locked. Without runtime measurement we'd be making confidence claims we can't back. Honest UI > confident-but-wrong UI.

**Consequences:** Users will need to bench (Activity Monitor, multi-instance run, before/after CPU/RAM/GPU samples) to know real deltas. The toggle's value is bundling 25 plausible flags into a single switch instead of forcing per-flag user research. Expected outcome on bench: noticeable drop on at least the rendering-side flags (post-FX, shadows, grass, wind), uncertain on telemetry, possibly no-op on the lower-level flags.

## Decision 5 — Surface as a single Settings toggle, not a fine-grained UI

**Decision:** `SettingsView` gets one new section, "Low-resource mode," with a single toggle. No UI for per-flag inspection or per-cluster toggles.

**Rationale:** The bundle is a *posture* (low-resource for AFK/multi-instance) not a tunable. Per-flag UI would be ~25 toggles deep — overwhelming and not what users want. A power-user who needs per-flag control can use the existing programmatic `LaunchSettingsStore.setFFlags(_:)` API to override; the merge-order in Decision 3 ensures their overrides win.

**Consequences:** Discoverability is good (it's a section in Settings, like FPS cap) but the nuance is hidden in the description text. We rely on the description to communicate posture + Hyperion caveat. If users complain we're being too coarse, P3 can add a "Custom bundle…" expander.

## Implementation map

| Layer | File | What it does |
| --- | --- | --- |
| Domain — bundle | `App/RORORO/Domain/LowResourceFFlags.swift` | The curated flag dictionary + merge function |
| Domain — store | `App/RORORO/Domain/LaunchSettingsStore.swift` | `lowResourceMode: Bool` field + setter; included in `Snapshot` |
| Domain — launcher | `App/RORORO/Domain/RobloxLauncher.swift` | `applyLaunchSettings` merges bundle into effective fflag dict when `snapshot.lowResourceMode == true`, then calls `ClientSettingsWriter.write` |
| UI | `App/RORORO/UI/SettingsView.swift` | New "Low-resource mode" section with toggle + description |
| Tests | `App/ROROROTests/LowResourceFFlagsTests.swift` | 6 test cases — empty merge, override wins, addition alongside, multiple overrides, bundle invariants (no physics/network/sim), core flags present |

## Bench protocol (recommended next step)

Before declaring this delivers value:

1. **Baseline:** Multi-instance launch 4 RORORO accounts. Activity Monitor → process group filter on `RobloxPlayer`. Sample CPU, GPU, memory after 60 s of cycler stay-awake mode.
2. **Toggle ON, restart all:** Same 4-account launch with Low-resource mode enabled. Same 60 s sample.
3. **Compare:** CPU per-instance, total memory, GPU utilization. Expect at least 15–25% reduction on rendering-bound metrics; smaller or no change on CPU-pure paths if Hyperion locks some flags.
4. **Per-cluster bisection (optional):** if total delta is small, bisect by removing one cluster at a time from the bundle. Identify which clusters Hyperion has locked vs which deliver value.

Bench results should be logged via `mcp__626Labs__manage_decisions log` with title *"Low-resource bundle bench (NN-instance, NN-min run)"* so future curation has data to refer to.

## References

- ADR 0001 — Launch settings writers (FFlag + FramerateCap)
- ADR 0005 — Window layout tool (Slope D, motivated this slope's pivot to throughput)
- github.com/Dantezz025/Roblox-Fast-Flags — primary source (149 flags, Feb 2025)
- github.com/AppleBlox/appleblox — cross-reference
- `App/RORORO/Domain/ClientSettingsWriter.swift` — proven JSON write surface this ADR builds on
