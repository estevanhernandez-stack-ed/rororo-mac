# Framerate-override visibility — design

**Date:** 2026-05-14
**Status:** Approved (brainstorming complete; ready for implementation plan)
**Origin:** `/vibe-iterate:ux-polish` — surfaced during the FFlag PR (#2) smoke test
**Approach:** B (warn-pill inside the existing launch button, divergence-only)

## Context

Setting the global FPS cap in Settings is silently overridden by per-account
`framerateCapOverride` (ADR 0002). The smoke test for the FFlag PR exposed the
trap: user set the global to 144, launched, got 20, with no surfaced reason.

Two surfaces fail the user:

1. **Settings copy lies** — `SettingsView.swift:79` says "every running instance
   is throttled at this rate uniformly," which is false the moment any account
   has an override.
2. **Override badge is invisible** — `AccountsListView.swift:668-676` already
   renders `"20FPS"` per-row when an override is set, but mono-micro
   white-at-0.85 inside the cyan launch-button gradient is easy to miss, and the
   wording carries no "override" semantic.

Both halves of the same trap. Bundled as one polish.

## Goals

- Honest Settings copy that names the per-account override mechanism.
- Visible override badge that warns **only when the override actually diverges
  from the global** — no nag when match, no nag when no global is set.
- Pure, testable divergence rule.

## Non-goals

- Surface "N accounts override this cap" inside Settings (queued for next
  ux-polish iteration).
- Rename the chevron menu's "Frame rate cap (this account)" → "...override..."
  (queued — cosmetic).
- Launch-time transient signal when effective cap ≠ global (queued — heaviest).

## Constraints

- **Small diff** (<50 LOC across 3 source files + 1 new test file). This is a
  polish, not a refactor.
- **Existing badge stays for the no-global case** — when there's no global cap,
  the override is "your only opinion," not a divergence to warn about; render
  the current subtle styling.
- **Pure divergence rule lives in Domain**, not UI — UI imports the rule, the
  rule has no SwiftUI dependency.

## Architecture

Three render states for the override badge:

| Override | Global | Render |
|---|---|---|
| `nil` | any | no badge |
| set | `nil` | **neutral pill** (today's subtle styling) |
| set | `== override` | **neutral pill** |
| set | `≠ override` | **warn pill** (Theme.Color.stateWarn background, dark text, ⚠ + value) |

The divergence rule (`override != nil && global != nil && override != global`)
lives in a new pure Domain helper. The view selects styling from it.

## Components

### New

**`App/RORORO/Domain/FramerateOverrideDivergence.swift`** — `enum`-namespaced
pure helper:

```swift
public enum FramerateOverrideDivergence {
    /// True when a per-account override should be flagged as a user-visible
    /// divergence from the global: only when global is concretely set AND
    /// the override differs from it. When global is nil, the override is
    /// "your only opinion" — no divergence to warn about. When override is
    /// nil, there is no override to flag.
    public static func diverges(override: Int?, global: Int?) -> Bool {
        guard let override, let global else { return false }
        return override != global
    }
}
```

No UI dependency. Fully unit-testable.

**`App/ROROROTests/FramerateOverrideDivergenceTests.swift`** — four cases:

| Case | Expected |
|---|---|
| `override = nil, global = 144` | `false` |
| `override = 20, global = nil` | `false` |
| `override = 20, global = 20` | `false` |
| `override = 20, global = 144` | `true` |

### Modified

**`App/RORORO/UI/SettingsView.swift`** — Frame rate section copy fix. Replace
the conditional `Text` block (line ~78-82) with the new copy:

> "Roblox-wide cap by default — per-account overrides (set on the account row)
> win when present. Applied at next launch; already-running instances keep their
> current cap until restart."

The `framerateCapEnabled` conditional flattens to one message because the new
copy is honest in both states. (When `framerateCapEnabled == false`, the cap
is unset — the same sentence reads correctly: there's no global to be
overridden, but the per-account-overrides-win mechanism still exists.)

**`App/RORORO/UI/AccountsListView.swift`** — two changes:

1. **Plumb global cap to the row.** Add
   `@ObservedObject private var launchSettings = LaunchSettingsStore.shared` to
   `AccountsListView`, then pass `globalFramerateCap: launchSettings.framerateCap`
   into each `AccountRow` via a new init parameter. The list reactively
   re-renders when the global changes.

2. **Warn-pill styling on divergence.** Replace the existing
   `if let cap = account.framerateCapOverride { Text(...) }` block (lines
   668-676) with a switch on `FramerateOverrideDivergence.diverges(...)`:

   ```swift
   if let cap = account.framerateCapOverride {
       let isWarn = FramerateOverrideDivergence.diverges(
           override: cap, global: globalFramerateCap
       )
       overrideBadge(cap: cap, warn: isWarn)
   }
   ```

   `overrideBadge(cap:warn:)` is a small private view helper on `AccountRow`:
   - **warn = true:** amber pill — `Theme.Color.stateWarn` background,
     `Theme.Color.bgPage` text, `⚠ \(cap)`, padded
     `.padding(.horizontal, 7).padding(.vertical, 3)`, rounded `4`
   - **warn = false:** today's subtle in-button styling preserved verbatim
     (`Text("\(cap)FPS")`, mono-micro, white-0.85, etc.)

   Tooltip on the warn pill via `.help(...)`:
   `"Per-account override: \(cap)fps. Global is \(global)fps."` — `global` is
   guaranteed non-nil when the warn pill renders (the divergence rule short-
   circuits when global is nil), so no defensive nil branch.

   Accessibility label on the warn pill:
   `"Per-account framerate cap override: \(cap) frames per second; differs from global setting"`.

## Data flow

- `LaunchSettingsStore.shared` is already `@MainActor` and `ObservableObject`;
  adding it as `@ObservedObject` in `AccountsListView` triggers re-renders when
  `framerateCap` changes.
- `globalFramerateCap` flows down: `AccountsListView` → `row(for:...)` →
  `AccountRow(globalFramerateCap:...)`.
- `AccountRow` calls `FramerateOverrideDivergence.diverges(override:, global:)`
  per render to pick the styling.

## Error handling

None new. The divergence helper takes optionals and returns `Bool`; no failure
modes. The view styling is deterministic per the truth table.

## Testing

- `FramerateOverrideDivergenceTests` — four pure cases, table-driven if
  preferred.
- `AccountsListView` and `SettingsView` follow the existing untested-view
  pattern (matches the rest of the UI in the repo).
- Manual visual check covers the three render states (no-badge, neutral, warn)
  + the Settings copy.

## File-level change map

| File | Change |
| --- | --- |
| `App/RORORO/Domain/FramerateOverrideDivergence.swift` | New — pure helper |
| `App/ROROROTests/FramerateOverrideDivergenceTests.swift` | New — 4 tests |
| `App/RORORO/UI/SettingsView.swift` | Frame rate section copy fix |
| `App/RORORO/UI/AccountsListView.swift` | `@ObservedObject launchSettings`; `globalFramerateCap` plumbed into `AccountRow`; badge swap with divergence-driven styling |
