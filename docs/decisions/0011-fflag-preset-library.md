# ADR 0011 — FFlag preset library + editor

**Date:** 2026-05-14
**Status:** Accepted (PerformanceFFlags bundle untested at runtime — requires bench, like ADR 0006)
**Slope:** A (FFlag injection — builds on ADR 0001 + ADR 0006)
**Origin:** `/vibe-iterate:competitive` — top-ranked gap; design spec at
`docs/superpowers/specs/2026-05-14-fflag-preset-library-design.md`

## Background

ADR 0006 shipped one curated FFlag bundle (`LowResourceFFlags`) behind a
single Settings toggle. A competitive scan found both third-party Mac
launchers had moved on FastFlags — AppleBlox expanded its preset set,
Bloxstrap shipped a Fast Flag editor. RORORO had the write substrate
(`ClientSettingsWriter`, `LaunchSettingsStore.fflags`) but no preset
library and no user-facing editor.

## Decision 1 — `activePreset` replaces the `lowResourceMode` toggle

`LaunchSettingsStore.lowResourceMode: Bool` becomes
`activePreset: FFlagPresetID?`. A one-time UserDefaults migration in
`init` maps a legacy `lowResourceMode == true` to
`activePreset == .lowResource` and clears the old key. The user's `fflags`
dict is unchanged — it stays the override layer.

**Rationale:** "pick a base, tweak on top" is a clearer model than a lone
boolean, and it generalizes to N presets without N booleans.

## Decision 2 — `FFlagPresetLibrary` is the registry + the merge point

A new `FFlagPresetLibrary` enum holds the preset list and
`effectiveFlags(for:userOverrides:)` — the single launch-time merge
(preset bundle, user overrides on top, user wins on collision). This
generalizes and replaces `LowResourceFFlags.merged(into:)`, which is
removed. Curated bundle constants (`LowResourceFFlags`,
`PerformanceFFlags`) stay in their own files.

## Decision 3 — `PerformanceFFlags`: a second curated bundle, render-only

`PerformanceFFlags.bundle` is an FPS-focused bundle, lighter than
low-resource: it kills pure overhead (telemetry, wind), the cheapest big
render cost (post-FX), tames grass, and pins Metal — but leaves lighting,
shadows, and textures at the game's own quality. Same posture as ADR 0006
(render + telemetry only, no physics/network/sim) and the same caveat:
ships untested at runtime, Hyperion may no-op entries, bench before
trusting.

## Decision 4 — arbitrary editor: inform, don't block

The `FFlagsSheet` editor accepts any flag the user types. Flags whose
names match known-risky patterns (physics/network/simulation, via
`RiskyFFlagPatterns`) get a non-blocking caution badge citing ADR 0006's
bannable-flag reasoning. RORORO is not adding anti-detection — the user
is choosing their own flags; RORORO's job is to inform, not nanny.

## Decision 5 — global scope, stated plainly

The editor is global. The write surface (`ClientAppSettings.json`) is one
file every Roblox instance reads; per-account FFlags remain deferred
(ADR 0002). The sheet's subtitle says so: "Global — applies to every
Roblox instance at launch."

## Consequences

- `LastAppliedFFlagsStore.Snapshot` swapped `lowResourceMode: Bool` for
  `activePreset: FFlagPresetID?`. A pre-0011 persisted record decodes with
  `activePreset == nil` (optional field, `decodeIfPresent`); no crash, no
  load-bearing loss.
- The FFlags sheet is presented from `SettingsView` (sheet-on-sheet).
- The `lowResourceMode → activePreset` rename rippled through
  `LaunchSettingsStore`, `LastAppliedFFlagsStore`, `RobloxLauncher`,
  `SettingsView`, and `DiagnosticsView`; it landed as one atomic commit
  because a load-bearing API rename can't compile half-done.
- `PerformanceFFlags` needs a runtime bench (same protocol as ADR 0006)
  before its real deltas are known.

## Implementation map

See `docs/superpowers/plans/2026-05-14-fflag-preset-library.md` for the
task-by-task plan and the full file-level change list, and
`docs/checklist.md` for the build checklist.
