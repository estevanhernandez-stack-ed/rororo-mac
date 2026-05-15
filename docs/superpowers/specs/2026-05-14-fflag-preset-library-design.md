# FFlag preset library + editor — design

**Date:** 2026-05-14
**Status:** Approved (brainstorming complete; ready for implementation plan)
**Origin:** `/vibe-iterate:competitive` — top-ranked gap (`:rate` 21/25, ship-now band)
**Approach:** A — active preset + overrides, dedicated sheet

## Context

A competitive scan (radar cache 2026-05-11) surfaced that both third-party Mac
competitors moved on FastFlags: AppleBlox 0.9.0 expanded its FastFlags presets,
Bloxstrap v2.11.x shipped a Fast Flag editor. RORORO Mac has the *substrate* —
`ClientSettingsWriter`, `LaunchSettingsStore.fflags` + `setFFlags()`,
`AnyCodableValue` — but only **one** preset (`LowResourceFFlags`) surfaced as a
single Settings toggle, and **no user-facing editor**. ADR 0001's open
follow-ups already name it: *"A1 presets — UI surface deferred; substrate is
in."* This design closes both competitor gaps with an additive UI layer over
proven domain code.

## Goals

- A **preset library**: curated FFlag bundles applied with one click. Ships with
  two — `Low-resource` (existing `LowResourceFFlags.bundle`, folded in) and a new
  `Performance` (FPS boost). The library is extensible to more presets later.
- An **arbitrary editor**: a table where power users add / edit / remove any
  FFlag key-value pair, layered on top of the active preset.
- A **non-blocking safety signal**: flags matching known-risky patterns
  (physics / network / simulation) get a caution badge citing ADR 0006's
  bannable-flag reasoning. RORORO informs; the user decides.

## Non-goals

- **Per-account FFlags.** The write surface (`ClientAppSettings.json`) is one
  file every Roblox instance reads — per-account FFlags are explicitly deferred
  (ADR 0002). This is a **global** editor; the UI says so plainly, the same
  honesty the FPS-cap section already uses.
- **Hard-blocking risky flags.** Considered and rejected — it nannies the power
  user and the risky-list is a guess that goes stale.
- **Re-curating `LowResourceFFlags`.** That bundle ships as-is; ADR 0006 stands.

## Constraints

- **Global scope is fixed.** Not a design variable — a substrate fact. UI copy
  must never imply per-instance or per-account behavior
  (`feedback_ui_must_match_capability_reality`).
- **User-trust-aware migration.** Users with `lowResourceMode = true` today must
  see byte-identical launch behavior after the upgrade.
- **Substrate is frozen.** `ClientSettingsWriter`, `AnyCodableValue`, the
  launch-time write hook — all untouched. This change is additive types plus one
  field swap on `LaunchSettingsStore`.

## Architecture & data model

New Domain types, each its own small focused file:

| Type | Shape | Purpose |
| --- | --- | --- |
| `FFlagPresetID` | `enum: .lowResource, .performance` — `Codable`, `CaseIterable` | The persisted identity of the active preset |
| `FFlagPreset` | `struct: id, displayName, summary, bundle: [String: AnyCodableValue]` | A named curated bundle + its card metadata |
| `FFlagPresetLibrary` | `enum` registry — `all: [FFlagPreset]`, `preset(_ id:)` | The lookup. References `LowResourceFFlags.bundle` + new `PerformanceFFlags.bundle` |
| `PerformanceFFlags` | `enum` with a `bundle` constant | New curated FPS-boost bundle, mirroring `LowResourceFFlags`'s file shape |
| `RiskyFFlagPatterns` | `enum` — `risk(for key: String) -> FFlagRiskCategory?` | Pattern-matches a flag name to `.physics` / `.network` / `.simulation` for the caution badge |

**`LaunchSettingsStore` changes:**

- `lowResourceMode: Bool` → `activePreset: FFlagPresetID?`, with `setActivePreset(_:)`.
- `fflags: [String: AnyCodableValue]` + `setFFlags(_:)` stay **exactly as-is** —
  that is the user-override dict the editor writes to.
- `Snapshot.lowResourceMode` → `Snapshot.activePreset`.

The curated-bundle constants (`LowResourceFFlags`, `PerformanceFFlags`) stay in
their own files; `FFlagPresetLibrary` only references them. This keeps each
bundle small, focused, and individually ADR-documented.

## UI layout

A new **FFlags sheet** — a peer of the Games / Diagnostics / Settings sheets,
opened from a "FFlags…" button in `SettingsView` that **replaces** today's
standalone low-resource toggle.

Layout: **stacked** (chosen over two-pane — Roblox flag names are long, e.g.
`DFFlagDebugRenderForceTechnologyVoxel`, and the editor table needs full sheet
width).

```
┌─ FFlags ───────────────────────────────────────────┐
│ Global — applies to every Roblox instance at launch│
│                                                     │
│ PRESET                                              │
│ ┌─ None ──┐ ┌─ Low-resource ─┐ ┌─ Performance ──┐  │
│ │ overrides│ │ AFK / multi-   │ │ FPS boost,     │  │
│ │ only     │ │ instance grind │ │ still watchable│  │
│ └──────────┘ └════ active ════┘ └────────────────┘  │
│ ─────────────────────────────────────────────────── │
│ YOUR OVERRIDES                          [+ Add flag]│
│  FFlagDebugGraphicsPreferMetal   [true ] Bool     × │
│  DFIntTaskSchedulerTargetFps     [240  ] Int  ⚠ sim × │
│                                                     │
│                                          [ Done ]   │
└─────────────────────────────────────────────────────┘
```

- **Preset cards** — `None` + one per `FFlagPresetID`. Selecting one calls
  `setActivePreset`. The active card carries the cyan highlight (`brandCyan`).
- **Override table** — one row per entry in `LaunchSettingsStore.fflags`. Row =
  key (monospace) + value field + type label + caution badge (if risky) + remove
  (×). Honest "global" subtitle under the title.

## Editor mechanics

- **Add flag**: a row with a key text field, a value field, and a
  `Bool / Int / Double / String` segmented control mapping to `AnyCodableValue`'s
  four cases.
- **Validation** is inline and local — the Int field rejects non-numeric input,
  Bool is a toggle, etc. A row that does not validate cannot be committed. No
  modals; no error state ever reaches launch time.
- **Caution badge** runs `RiskyFFlagPatterns.risk(for:)` live as the key is
  typed. Non-blocking — the row still saves with the badge shown.
- **Duplicate keys** are impossible: the override store is keyed, so adding an
  existing key scrolls to and highlights the existing row instead of inserting a
  silent duplicate.

## Data flow at launch

`RobloxLauncher.applyLaunchSettings` (the existing Step 4.5 hook):

1. Resolve `snapshot.activePreset` → its bundle via `FFlagPresetLibrary` (or `[:]`
   when `nil`).
2. Merge `snapshot.fflags` on top — **user value wins on key collision**.
   Identical semantics to today's `LowResourceFFlags.merged(into:)`, generalized
   to "the active preset's bundle."
3. Write via `ClientSettingsWriter` — unchanged.
4. Record to `LastAppliedFFlagsStore` with the preset ID alongside the flags, so
   Diagnostics still answers "what got written, and which preset was folded in?"

Roblox-exit cleanup (`ClientSettingsWriter.cleanup()` via the coordinator) is
unchanged.

## Migration & backward compatibility

- **`LaunchSettingsStore.init`**: read the legacy `rororo.launch.lowResourceMode`
  Bool key — if `true`, set `activePreset = .lowResource` and clear the old key;
  if `false` or absent, `activePreset = nil`. Same pattern as the
  `startScreenSize` cleanup already living in `init`.
- **`Snapshot`** (in-process, `Sendable`/`Equatable`): the
  `lowResourceMode → activePreset` swap is a coordinated same-PR source change —
  all call sites (`RobloxLauncher`, `LastAppliedFFlagsStore`) update in lockstep.
- **`LastAppliedFFlagsStore.Snapshot`** (persisted, `Codable` to UserDefaults):
  the field swap means a legacy persisted record won't carry `activePreset`.
  Decode stays `try?`-tolerant — a stale legacy record simply drops and the next
  launch repopulates it. The store is a single last-launch diagnostic, not
  load-bearing; no user-visible loss.

## Error handling

- Launch-time writers stay **best-effort** — `NSLog` + continue, per ADR 0001.
  A misconfigured preset or override never aborts a launch.
- Editor input validation is inline and local; no launch-time error states.
- `FFlagPresetLibrary.preset(_:)` returns an optional; an unresolvable persisted
  ID (shouldn't happen — the enum is exhaustive) degrades to "no preset," never
  crashes.

## Testing

| Test file | Covers |
| --- | --- |
| `FFlagPresetLibraryTests` | Registry returns expected presets; `preset(_:)` lookup |
| `PerformanceFFlagsTests` | Bundle invariants — render-only posture, no physics/network/sim flags (mirrors `LowResourceFFlagsTests`) |
| `RiskyFFlagPatternsTests` | Known-risky keys flagged with the right category; safe keys not flagged |
| `LaunchSettingsStoreTests` | Migration: legacy `lowResourceMode=true` → `activePreset=.lowResource`, old key cleared, absent → `nil`; preset persistence round-trip |
| `RobloxLauncherTests` | `applyLaunchSettings` with active preset + overrides → correct merged dict, user value wins on collision (generalizes the existing low-resource merge test) |

SwiftUI views follow the existing untested-view pattern; all domain logic
underneath is fully covered.

## File-level change map

| File | Change |
| --- | --- |
| `App/RORORO/Domain/FFlagPresetID.swift` | New — the persisted enum |
| `App/RORORO/Domain/FFlagPreset.swift` | New — the preset struct |
| `App/RORORO/Domain/FFlagPresetLibrary.swift` | New — the registry |
| `App/RORORO/Domain/PerformanceFFlags.swift` | New — curated FPS-boost bundle |
| `App/RORORO/Domain/RiskyFFlagPatterns.swift` | New — risky-flag pattern matcher |
| `App/RORORO/Domain/LaunchSettingsStore.swift` | `lowResourceMode: Bool` → `activePreset: FFlagPresetID?`; migration in `init`; `Snapshot` field swap |
| `App/RORORO/Domain/RobloxLauncher.swift` | `applyLaunchSettings` resolves preset via `FFlagPresetLibrary`, generalizes the merge |
| `App/RORORO/Domain/LastAppliedFFlagsStore.swift` | `Snapshot.lowResourceMode` → `activePreset`; `try?`-tolerant decode |
| `App/RORORO/UI/FFlagsSheet.swift` | New — the stacked sheet (preset cards + override editor) |
| `App/RORORO/UI/SettingsView.swift` | Low-resource toggle → "FFlags…" button opening the sheet |
| `App/RORORO/UI/ContentView.swift` | Wire the new `.sheet` presentation |
| `App/RORORO/UI/DiagnosticsView.swift` | Show the recorded preset ID (if it surfaces low-resource today) |
| `App/ROROROTests/*` | The five test files above |
| `docs/decisions/0011-fflag-preset-library.md` | New ADR — data-model swap + `PerformanceFFlags` curation (0001-0010 exist; 0011 is next) |

## Follow-ups (out of scope here)

- Curating the `Performance` bundle happens during the build, source-triangulated
  the same way ADR 0006 did `LowResourceFFlags` (Dantezz / AppleBlox / Bloxstrap),
  render-only posture.
- More presets (`Max visuals`, `Mac-optimized baseline`) — deferred; the library
  shell makes them cheap to add later.
- Per-account FFlag overrides — still waiting on the deferred ADR 0002 follow-up.
