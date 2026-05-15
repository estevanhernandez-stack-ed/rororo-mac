<!-- Every item uses the five-field format. /build reads each item and
     relies on all five fields being present and consistently formatted.
     The header encodes methodology choices so /build doesn't re-ask. -->

# Build Checklist — FFlag Preset Library + Editor

> **Scope note for `/build`:** This is a *feature* build atop an already-shipped product. The load-bearing artifacts are the implementation plan at [`docs/superpowers/plans/2026-05-14-fflag-preset-library.md`](superpowers/plans/2026-05-14-fflag-preset-library.md) — which carries the **complete code, exact commands, and expected output for every step** — and the design spec at [`docs/superpowers/specs/2026-05-14-fflag-preset-library-design.md`](superpowers/specs/2026-05-14-fflag-preset-library-design.md). This checklist is the trackable surface; the plan is the source of truth. ADR 0011 is written in the final item.
>
> Origin: `/vibe-iterate:competitive` top-ranked gap (`:rate` 21/25). Branch: `feat/fflag-preset-library`.

## Build Preferences

- **Build mode:** Autonomous
- **Comprehension checks:** N/A (autonomous mode)
- **Git:** Commit per item with conventional-commit style, scoped `(fflags)`, exactly as each plan task specifies. Co-author trailer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`. **Tasks 5-7 commit together** as one coordinated `Snapshot`-shape change — never commit a broken build.
- **Verification:** Yes — checkpoint after items 3, 7, and 10. Orchestrator runs xcodebuild, reports result.
- **Check-in cadence:** N/A (autonomous); stop immediately to surface anything that deviates from the plan.

## Checklist

- [ ] **1. FFlagPresetID enum**
  Spec ref: `superpowers/plans/2026-05-14-fflag-preset-library.md > Task 1`
  What to build: Create `App/RORORO/Domain/FFlagPresetID.swift` — `public enum FFlagPresetID: String, Codable, CaseIterable, Sendable` with cases `.lowResource`, `.performance`. Create `App/ROROROTests/FFlagPresetIDTests.swift` (3 tests: allCases, Codable round-trip, raw-value stability). Full code in plan Task 1.
  Acceptance: 3 tests pass.
  Verify: `xcodegen generate --spec App/project.yml && xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -only-testing:ROROROTests/FFlagPresetIDTests 2>&1 | tail -10`. Expect 3 passed.

- [ ] **2. PerformanceFFlags curated bundle**
  Spec ref: `superpowers/plans/2026-05-14-fflag-preset-library.md > Task 2`
  What to build: Create `App/RORORO/Domain/PerformanceFFlags.swift` — render-only FPS-boost bundle (post-FX off, wind off, grass tamed, telemetry off, Metal pinned; ships untested-at-runtime per ADR 0006 posture). Create `App/ROROROTests/PerformanceFFlagsTests.swift` (4 tests: no physics/network/sim, non-empty, disables post-FX, lighter than low-resource). Full code in plan Task 2.
  Acceptance: 4 tests pass.
  Verify: `xcodegen generate --spec App/project.yml && xcodebuild ... test -only-testing:ROROROTests/PerformanceFFlagsTests 2>&1 | tail -10`. Expect 4 passed.

- [ ] **3. FFlagPreset struct + FFlagPresetLibrary registry**
  Spec ref: `superpowers/plans/2026-05-14-fflag-preset-library.md > Task 3`
  What to build: Create `App/RORORO/Domain/FFlagPreset.swift` (`Identifiable, Sendable` struct: id, displayName, summary, bundle) and `App/RORORO/Domain/FFlagPresetLibrary.swift` (`all`, `preset(_:)`, `effectiveFlags(for:userOverrides:)` — the single launch-time merge point, user wins on collision). Create `App/ROROROTests/FFlagPresetLibraryTests.swift` (9 tests: registry shape + merge semantics). Full code in plan Task 3.
  Acceptance: 9 tests pass.
  Verify: `xcodegen generate --spec App/project.yml && xcodebuild ... test -only-testing:ROROROTests/FFlagPresetLibraryTests 2>&1 | tail -10`. Expect 9 passed. **Checkpoint — report to orchestrator.**

- [ ] **4. RiskyFFlagPatterns matcher**
  Spec ref: `superpowers/plans/2026-05-14-fflag-preset-library.md > Task 4`
  What to build: Create `App/RORORO/Domain/RiskyFFlagPatterns.swift` — `FFlagRiskCategory` enum + `risk(for:)` substring matcher (physics/network/simulation). Create `App/ROROROTests/RiskyFFlagPatternsTests.swift` (7 tests, incl. no-false-positive against shipped bundles). Full code in plan Task 4.
  Acceptance: 7 tests pass.
  Verify: `xcodegen generate --spec App/project.yml && xcodebuild ... test -only-testing:ROROROTests/RiskyFFlagPatternsTests 2>&1 | tail -10`. Expect 7 passed.

- [ ] **5. LaunchSettingsStore migration — lowResourceMode → activePreset**
  Spec ref: `superpowers/plans/2026-05-14-fflag-preset-library.md > Task 5`
  What to build: Modify `App/RORORO/Domain/LaunchSettingsStore.swift` — swap `lowResourceMode: Bool` for `activePreset: FFlagPresetID?`, one-time UserDefaults migration in `init`, `setActivePreset(_:)`, `Snapshot` field swap, `Keys` update. Add 9 test methods + update `testSnapshot_ReflectsCurrentState` in `App/ROROROTests/LaunchSettingsStoreTests.swift`. Full code in plan Task 5. **Stage, do not commit** (coordinated with items 6-7).
  Acceptance: `LaunchSettingsStoreTests` are correct; project will not link yet (RobloxLauncher/LastAppliedFFlagsStore/DiagnosticsView still reference the old field — fixed in 6, 7, 10). Expected.
  Verify: `xcodebuild ... test -only-testing:ROROROTests/LaunchSettingsStoreTests 2>&1 | tail -15`. Expect compile error in dependent files only — proceed to item 6.

- [ ] **6. LastAppliedFFlagsStore.Snapshot — swap to activePreset**
  Spec ref: `superpowers/plans/2026-05-14-fflag-preset-library.md > Task 6`
  What to build: Modify `App/RORORO/Domain/LastAppliedFFlagsStore.swift` — `Snapshot.lowResourceMode: Bool` → `activePreset: FFlagPresetID?` (optional field → tolerant legacy decode). Create `App/ROROROTests/LastAppliedFFlagsStoreTests.swift` (3 tests: round-trip, nil round-trip, legacy-record decode). Full code in plan Task 6. **Stage, do not commit.**
  Acceptance: New test file correct; build still red on RobloxLauncher/DiagnosticsView. Expected.
  Verify: `xcodegen generate --spec App/project.yml && xcodebuild ... test -only-testing:ROROROTests/LastAppliedFFlagsStoreTests 2>&1 | tail -15`. Proceed to item 7.

- [ ] **7. RobloxLauncher.applyLaunchSettings — route through FFlagPresetLibrary**
  Spec ref: `superpowers/plans/2026-05-14-fflag-preset-library.md > Task 7`
  What to build: Modify `App/RORORO/Domain/RobloxLauncher.swift` (use `FFlagPresetLibrary.effectiveFlags`, record `activePreset`); remove dead `LowResourceFFlags.merged(into:)` from `App/RORORO/Domain/LowResourceFFlags.swift`; trim the four `testMerge_*` from `App/ROROROTests/LowResourceFFlagsTests.swift` (keep bundle-invariant tests). If the build is still red on `DiagnosticsView.swift`, apply item 10's edits now and fold in. Full code in plan Task 7. **Commits items 5-7 (and 10 if folded) as one build-green change.**
  Acceptance: Project compiles; `LowResourceFFlagsTests`, `FFlagPresetLibraryTests`, `LaunchSettingsStoreTests`, `LastAppliedFFlagsStoreTests` all green.
  Verify: `xcodegen generate --spec App/project.yml && xcodebuild ... test -only-testing:ROROROTests/LowResourceFFlagsTests -only-testing:ROROROTests/FFlagPresetLibraryTests -only-testing:ROROROTests/LaunchSettingsStoreTests -only-testing:ROROROTests/LastAppliedFFlagsStoreTests 2>&1 | tail -15`. Expect all green. **Checkpoint — report to orchestrator.**

- [ ] **8. FFlagsSheet editor UI**
  Spec ref: `superpowers/plans/2026-05-14-fflag-preset-library.md > Task 8`
  What to build: Create `App/RORORO/UI/FFlagsSheet.swift` — stacked sheet (preset cards + arbitrary key/value override editor with caution badges + inline validation; pure `EditorRow` model with `rowsFromStore`/`storeFromRows`/`parsedValue`/`parseError` statics). Create `App/ROROROTests/FFlagsSheetTests.swift` (10 tests on the pure editor model). Full code in plan Task 8.
  Acceptance: 10 tests pass.
  Verify: `xcodegen generate --spec App/project.yml && xcodebuild ... test -only-testing:ROROROTests/FFlagsSheetTests 2>&1 | tail -10`. Expect 10 passed.

- [ ] **9. Wire FFlags sheet into SettingsView**
  Spec ref: `superpowers/plans/2026-05-14-fflag-preset-library.md > Task 9`
  What to build: Modify `App/RORORO/UI/SettingsView.swift` — remove `lowResourceModeEnabled` state, add `showFFlags` state + `fflagsSummary` computed property, replace the "Low-resource mode" section with an "FFlags" section (button + summary), present `FFlagsSheet` via `.sheet`. Full code in plan Task 9. Sheet-on-sheet is a manual-verification watch-point.
  Acceptance: `** BUILD SUCCEEDED **`.
  Verify: `xcodegen generate --spec App/project.yml && xcodebuild -project App/RORORO.xcodeproj -scheme RORORO build -destination 'platform=macOS,arch=x86_64' 2>&1 | tail -5`.

- [ ] **10. Show active preset in DiagnosticsView**
  Spec ref: `superpowers/plans/2026-05-14-fflag-preset-library.md > Task 10`
  What to build: Modify `App/RORORO/UI/DiagnosticsView.swift` — add `presetLabel(_:)` helper, replace the "Low-resource mode" row with an "Active preset" row in `fflagsSection`, update the empty-state text and `copyAll()`. (If already folded into item 7's commit, this item is verification + a no-op commit-check.) Full code in plan Task 10.
  Acceptance: `** BUILD SUCCEEDED **`.
  Verify: `xcodegen generate --spec App/project.yml && xcodebuild ... build 2>&1 | tail -5`. **Checkpoint — report to orchestrator.**

- [ ] **11. ADR 0011 + full-suite verification**
  Spec ref: `superpowers/plans/2026-05-14-fflag-preset-library.md > Task 11`
  What to build: Create `docs/decisions/0011-fflag-preset-library.md` (ADR — 5 decisions, consequences, implementation map). Regenerate project, run the FULL test suite green, commit `docs(fflags): ADR 0011`. Full ADR text in plan Task 11.
  Acceptance: Full suite green (pre-existing CI-opt-in keychain suites excepted — confirm any failure also fails on `main`). ADR committed.
  Verify: `xcodegen generate --spec App/project.yml && xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' 2>&1 | tail -20`. Expect TEST SUCCEEDED. Hand back to orchestrator for the 626Labs Dashboard decision log + PR.
