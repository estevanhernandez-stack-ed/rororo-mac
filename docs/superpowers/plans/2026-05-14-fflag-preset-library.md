# FFlag Preset Library + Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a curated FFlag preset library plus an arbitrary key/value editor for RORORO Mac, surfaced in a dedicated sheet.

**Architecture:** Approach A from the design spec — `LaunchSettingsStore` gains an `activePreset: FFlagPresetID?` (the legacy `lowResourceMode: Bool` migrates into it); the user's `fflags` dict stays as overrides layered on top. A new `FFlagPresetLibrary` is the registry + the single launch-time merge point. A new `FFlagsSheet` is the UI. The FFlag write substrate (`ClientSettingsWriter`, `AnyCodableValue`, the launch hook) is untouched.

**Tech Stack:** Swift 5.9 / SwiftUI, XcodeGen (`App/project.yml` is source of truth; `.xcodeproj` is gitignored and regenerated), XCTest.

**Spec:** `docs/superpowers/specs/2026-05-14-fflag-preset-library-design.md`

## Conventions used by every task

- **Regenerate the project after creating any new file** (the `RORORO` and `ROROROTests` targets are folder globs, so XcodeGen picks new files up on regen):
  `xcodegen generate --spec App/project.yml`
- **Run one test class:**
  `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -only-testing:ROROROTests/<ClassName>`
- **Run the full suite:**
  `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64'`
- Commits are conventional (`feat` / `refactor` / `docs`), one per task, scoped `(fflags)`.
- Branch: `feat/fflag-preset-library` (already created; the design-spec commit is its first commit).

---

### Task 1: `FFlagPresetID` enum

**Files:**
- Create: `App/RORORO/Domain/FFlagPresetID.swift`
- Test: `App/ROROROTests/FFlagPresetIDTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// FFlagPresetIDTests.swift
import XCTest
@testable import RORORO

final class FFlagPresetIDTests: XCTestCase {

    func testAllCases_ContainsBothPresets() {
        XCTAssertEqual(Set(FFlagPresetID.allCases), [.lowResource, .performance])
    }

    func testCodable_RoundTripsThroughJSON() throws {
        for id in FFlagPresetID.allCases {
            let data = try JSONEncoder().encode(id)
            let decoded = try JSONDecoder().decode(FFlagPresetID.self, from: data)
            XCTAssertEqual(decoded, id)
        }
    }

    func testRawValue_IsStableWireString() {
        // The raw value is persisted to UserDefaults — renaming a case
        // without a migration would orphan a user's saved preset.
        XCTAssertEqual(FFlagPresetID.lowResource.rawValue, "lowResource")
        XCTAssertEqual(FFlagPresetID.performance.rawValue, "performance")
    }
}
```

- [ ] **Step 2: Regenerate project and run the test to verify it fails**

Run: `xcodegen generate --spec App/project.yml`
Then: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -only-testing:ROROROTests/FFlagPresetIDTests`
Expected: FAIL — compile error, `cannot find 'FFlagPresetID' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
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
```

- [ ] **Step 4: Regenerate project and run the test to verify it passes**

Run: `xcodegen generate --spec App/project.yml`
Then: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -only-testing:ROROROTests/FFlagPresetIDTests`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add App/RORORO/Domain/FFlagPresetID.swift App/ROROROTests/FFlagPresetIDTests.swift
git commit -m "feat(fflags): add FFlagPresetID enum"
```

---

### Task 2: `PerformanceFFlags` curated bundle

**Files:**
- Create: `App/RORORO/Domain/PerformanceFFlags.swift`
- Test: `App/ROROROTests/PerformanceFFlagsTests.swift`

**Note:** This bundle is a defensible starter selection — a lighter subset of the well-documented `LowResourceFFlags` flags, chosen for "FPS win, stays watchable." Like `LowResourceFFlags` (ADR 0006), it ships "untested at runtime — requires bench"; the ADR in Task 11 records that.

- [ ] **Step 1: Write the failing test**

```swift
// PerformanceFFlagsTests.swift
import XCTest
@testable import RORORO

final class PerformanceFFlagsTests: XCTestCase {

    func testBundle_NoPhysicsNetworkOrSimulationFlags() {
        // Same posture as LowResourceFFlags: render + telemetry only.
        // Physics/network/sim flags can break gameplay or trip anti-cheat.
        for key in PerformanceFFlags.bundle.keys {
            XCTAssertFalse(key.contains("Physics"), "Bundle includes physics flag: \(key)")
            XCTAssertFalse(key.contains("Network"), "Bundle includes network flag: \(key)")
            XCTAssertFalse(key.contains("RakNet"),  "Bundle includes RakNet flag: \(key)")
            XCTAssertFalse(key.contains("Sim") && !key.contains("Simulation"),
                           "Bundle includes simulation-tweak flag: \(key)")
        }
    }

    func testBundle_IsNonEmpty() {
        XCTAssertFalse(PerformanceFFlags.bundle.isEmpty)
    }

    func testBundle_DisablesPostFx_TheCoreFpsWin() {
        XCTAssertEqual(PerformanceFFlags.bundle["FFlagDisablePostFx"], .bool(true))
    }

    func testBundle_LighterThanLowResource_DoesNotForceLowestQuality() {
        // Performance keeps the game watchable — unlike LowResourceFFlags
        // it must NOT force the lowest render-quality preset.
        XCTAssertNil(PerformanceFFlags.bundle["DFIntDebugFRMQualityLevelOverride"],
                     "Performance bundle should not force lowest render quality")
    }
}
```

- [ ] **Step 2: Regenerate project and run the test to verify it fails**

Run: `xcodegen generate --spec App/project.yml`
Then: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -only-testing:ROROROTests/PerformanceFFlagsTests`
Expected: FAIL — `cannot find 'PerformanceFFlags' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
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
```

- [ ] **Step 4: Regenerate project and run the test to verify it passes**

Run: `xcodegen generate --spec App/project.yml`
Then: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -only-testing:ROROROTests/PerformanceFFlagsTests`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add App/RORORO/Domain/PerformanceFFlags.swift App/ROROROTests/PerformanceFFlagsTests.swift
git commit -m "feat(fflags): add PerformanceFFlags curated bundle"
```

---

### Task 3: `FFlagPreset` struct + `FFlagPresetLibrary` registry

**Files:**
- Create: `App/RORORO/Domain/FFlagPreset.swift`
- Create: `App/RORORO/Domain/FFlagPresetLibrary.swift`
- Test: `App/ROROROTests/FFlagPresetLibraryTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// FFlagPresetLibraryTests.swift
// Domain — registry shape + the launch-time merge semantics. The merge
// tests were previously in LowResourceFFlagsTests against
// LowResourceFFlags.merged(into:); they move here now that the merge is
// generalized to effectiveFlags(for:userOverrides:).

import XCTest
@testable import RORORO

final class FFlagPresetLibraryTests: XCTestCase {

    // MARK: - registry

    func testAll_ContainsExactlyTheRegisteredPresets() {
        XCTAssertEqual(FFlagPresetLibrary.all.map(\.id), [.lowResource, .performance])
    }

    func testPreset_ResolvesEveryID() {
        for id in FFlagPresetID.allCases {
            XCTAssertNotNil(FFlagPresetLibrary.preset(id), "No preset registered for \(id)")
        }
    }

    func testPreset_LowResource_WrapsLowResourceBundle() {
        XCTAssertEqual(FFlagPresetLibrary.preset(.lowResource)?.bundle.count,
                       LowResourceFFlags.bundle.count)
    }

    func testPreset_Performance_WrapsPerformanceBundle() {
        XCTAssertEqual(FFlagPresetLibrary.preset(.performance)?.bundle.count,
                       PerformanceFFlags.bundle.count)
    }

    // MARK: - effectiveFlags

    func testEffectiveFlags_NilPreset_ReturnsUserOverridesOnly() {
        let overrides: [String: AnyCodableValue] = ["FFlagA": .bool(true)]
        let result = FFlagPresetLibrary.effectiveFlags(for: nil, userOverrides: overrides)
        XCTAssertEqual(result, overrides)
    }

    func testEffectiveFlags_NilPresetEmptyOverrides_ReturnsEmpty() {
        let result = FFlagPresetLibrary.effectiveFlags(for: nil, userOverrides: [:])
        XCTAssertTrue(result.isEmpty)
    }

    func testEffectiveFlags_PresetOnly_ReturnsBundleAsIs() {
        let result = FFlagPresetLibrary.effectiveFlags(for: .lowResource, userOverrides: [:])
        XCTAssertEqual(result.count, LowResourceFFlags.bundle.count)
        XCTAssertEqual(result["FFlagDisablePostFx"], .bool(true))
    }

    func testEffectiveFlags_UserOverrideWinsOnCollision() {
        // LowResourceFFlags sets DFIntDebugFRMQualityLevelOverride to 1.
        // A user override of 10 MUST win.
        let result = FFlagPresetLibrary.effectiveFlags(
            for: .lowResource,
            userOverrides: ["DFIntDebugFRMQualityLevelOverride": .int(10)]
        )
        XCTAssertEqual(result["DFIntDebugFRMQualityLevelOverride"], .int(10))
    }

    func testEffectiveFlags_UserOverrideNotInBundle_AddedAlongside() {
        let result = FFlagPresetLibrary.effectiveFlags(
            for: .lowResource,
            userOverrides: ["FFlagSomeUserSpecificThing": .bool(true)]
        )
        XCTAssertEqual(result["FFlagSomeUserSpecificThing"], .bool(true))
        XCTAssertEqual(result["FFlagDisablePostFx"], .bool(true))
        XCTAssertEqual(result.count, LowResourceFFlags.bundle.count + 1)
    }
}
```

- [ ] **Step 2: Regenerate project and run the test to verify it fails**

Run: `xcodegen generate --spec App/project.yml`
Then: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -only-testing:ROROROTests/FFlagPresetLibraryTests`
Expected: FAIL — `cannot find 'FFlagPresetLibrary' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// FFlagPreset.swift
// Domain — a named curated FFlag bundle plus the metadata the FFlags
// sheet's preset card needs. Created only by FFlagPresetLibrary; the
// curated bundle constants (LowResourceFFlags, PerformanceFFlags) live
// in their own files and this just wraps them.

import Foundation

public struct FFlagPreset: Identifiable, Sendable {
    public let id: FFlagPresetID
    /// Card title, e.g. "Low-resource".
    public let displayName: String
    /// One-line card body, e.g. "AFK / multi-instance grind".
    public let summary: String
    /// The curated flag dictionary merged in at launch time.
    public let bundle: [String: AnyCodableValue]

    public init(
        id: FFlagPresetID,
        displayName: String,
        summary: String,
        bundle: [String: AnyCodableValue]
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.bundle = bundle
    }
}
```

```swift
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
```

- [ ] **Step 4: Regenerate project and run the test to verify it passes**

Run: `xcodegen generate --spec App/project.yml`
Then: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -only-testing:ROROROTests/FFlagPresetLibraryTests`
Expected: PASS — 9 tests.

- [ ] **Step 5: Commit**

```bash
git add App/RORORO/Domain/FFlagPreset.swift App/RORORO/Domain/FFlagPresetLibrary.swift App/ROROROTests/FFlagPresetLibraryTests.swift
git commit -m "feat(fflags): add FFlagPreset + FFlagPresetLibrary registry"
```

---

### Task 4: `RiskyFFlagPatterns` matcher

**Files:**
- Create: `App/RORORO/Domain/RiskyFFlagPatterns.swift`
- Test: `App/ROROROTests/RiskyFFlagPatternsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// RiskyFFlagPatternsTests.swift
import XCTest
@testable import RORORO

final class RiskyFFlagPatternsTests: XCTestCase {

    func testRisk_PhysicsFlag_FlaggedAsPhysics() {
        XCTAssertEqual(RiskyFFlagPatterns.risk(for: "DFIntPhysicsSenderRate"), .physics)
    }

    func testRisk_NetworkFlag_FlaggedAsNetwork() {
        XCTAssertEqual(RiskyFFlagPatterns.risk(for: "FFlagDebugNetworkBandwidthLog"), .network)
    }

    func testRisk_RakNetFlag_FlaggedAsNetwork() {
        XCTAssertEqual(RiskyFFlagPatterns.risk(for: "DFIntRakNetResendBufferArrayLength"), .network)
    }

    func testRisk_SimulationFlag_FlaggedAsSimulation() {
        XCTAssertEqual(RiskyFFlagPatterns.risk(for: "DFIntSimulationRadius"), .simulation)
    }

    func testRisk_SafeRenderFlags_NotFlagged() {
        XCTAssertNil(RiskyFFlagPatterns.risk(for: "FFlagDisablePostFx"))
        XCTAssertNil(RiskyFFlagPatterns.risk(for: "FFlagDebugGraphicsPreferMetal"))
        XCTAssertNil(RiskyFFlagPatterns.risk(for: "DFIntTextureQualityOverride"))
    }

    func testRisk_MatchIsCaseInsensitive() {
        XCTAssertEqual(RiskyFFlagPatterns.risk(for: "fflagsomephysicsthing"), .physics)
    }

    func testRisk_NoFalsePositiveAgainstShippedBundles() {
        // Neither curated bundle should trip the matcher — they are
        // render + telemetry only by design.
        for key in LowResourceFFlags.bundle.keys {
            XCTAssertNil(RiskyFFlagPatterns.risk(for: key), "False positive on \(key)")
        }
        for key in PerformanceFFlags.bundle.keys {
            XCTAssertNil(RiskyFFlagPatterns.risk(for: key), "False positive on \(key)")
        }
    }
}
```

- [ ] **Step 2: Regenerate project and run the test to verify it fails**

Run: `xcodegen generate --spec App/project.yml`
Then: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -only-testing:ROROROTests/RiskyFFlagPatternsTests`
Expected: FAIL — `cannot find 'RiskyFFlagPatterns' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// RiskyFFlagPatterns.swift
// Domain — pattern-matches an FFlag name to a risk category so the FFlags
// sheet can show a non-blocking caution badge. The editor still SAVES a
// risky flag (per the design's "inform, don't block" posture, ADR 0011);
// this is purely the signal feeding the badge.
//
// The categories mirror ADR 0006's exclusion rationale: physics / network
// / simulation flags can break gameplay or trip anti-cheat in some
// titles. Match is substring-based and deliberately conservative — false
// negatives (a risky flag not flagged) are better than false positives
// (a safe flag nagged), since the badge is advisory, not a gate.

import Foundation

public enum FFlagRiskCategory: String, Sendable {
    case physics
    case network
    case simulation
}

public enum RiskyFFlagPatterns {

    /// Substring → category, checked case-insensitively against the flag
    /// name. Listed highest-severity first so it surfaces on a multi-match.
    private static let patterns: [(needle: String, category: FFlagRiskCategory)] = [
        ("physics",    .physics),
        ("raknet",     .network),
        ("network",    .network),
        ("simulation", .simulation),
        ("simradius",  .simulation),
    ]

    /// Returns the risk category for `key`, or nil when it matches no
    /// known-risky pattern. nil is NOT a safety guarantee — it means
    /// "nothing recognized," which is why the badge copy says "may be
    /// risky" rather than asserting safety.
    public static func risk(for key: String) -> FFlagRiskCategory? {
        let haystack = key.lowercased()
        for (needle, category) in patterns where haystack.contains(needle) {
            return category
        }
        return nil
    }
}
```

- [ ] **Step 4: Regenerate project and run the test to verify it passes**

Run: `xcodegen generate --spec App/project.yml`
Then: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -only-testing:ROROROTests/RiskyFFlagPatternsTests`
Expected: PASS — 7 tests.

- [ ] **Step 5: Commit**

```bash
git add App/RORORO/Domain/RiskyFFlagPatterns.swift App/ROROROTests/RiskyFFlagPatternsTests.swift
git commit -m "feat(fflags): add RiskyFFlagPatterns matcher"
```

---

### Task 5: Migrate `LaunchSettingsStore` — `lowResourceMode` → `activePreset`

**Files:**
- Modify: `App/RORORO/Domain/LaunchSettingsStore.swift`
- Test: `App/ROROROTests/LaunchSettingsStoreTests.swift` (add cases)

- [ ] **Step 1: Write the failing tests** — append to `LaunchSettingsStoreTests.swift`, and update the existing `testSnapshot_ReflectsCurrentState`.

Replace the existing `testSnapshot_ReflectsCurrentState` with:

```swift
    func testSnapshot_ReflectsCurrentState() {
        let store = LaunchSettingsStore(defaults: defaults)
        store.setFramerateCap(20)
        store.setFFlags(["FFlagDebugGraphicsPreferMetal": .bool(true)])
        store.setActivePreset(.performance)

        let snapshot = store.snapshot()

        XCTAssertEqual(snapshot.framerateCap, 20)
        XCTAssertEqual(snapshot.fflags["FFlagDebugGraphicsPreferMetal"], .bool(true))
        XCTAssertEqual(snapshot.activePreset, .performance)
    }
```

Append these new test methods to the class:

```swift
    // MARK: - activePreset (ADR 0011)

    func testActivePreset_DefaultsToNil() {
        let store = LaunchSettingsStore(defaults: defaults)
        XCTAssertNil(store.activePreset)
    }

    func testActivePreset_PersistsAcrossInstances() {
        let store = LaunchSettingsStore(defaults: defaults)
        store.setActivePreset(.performance)

        let reborn = LaunchSettingsStore(defaults: defaults)
        XCTAssertEqual(reborn.activePreset, .performance)
    }

    func testActivePreset_ClearsWhenSetToNil() {
        let store = LaunchSettingsStore(defaults: defaults)
        store.setActivePreset(.lowResource)
        store.setActivePreset(nil)

        let reborn = LaunchSettingsStore(defaults: defaults)
        XCTAssertNil(reborn.activePreset)
    }

    // MARK: - migration: legacy lowResourceMode → activePreset

    func testMigration_LegacyLowResourceModeTrue_BecomesLowResourcePreset() {
        defaults.set(true, forKey: "rororo.launch.lowResourceMode")

        let store = LaunchSettingsStore(defaults: defaults)
        XCTAssertEqual(store.activePreset, .lowResource)
    }

    func testMigration_LegacyLowResourceModeTrue_ClearsOldKey() {
        defaults.set(true, forKey: "rororo.launch.lowResourceMode")
        _ = LaunchSettingsStore(defaults: defaults)
        // Old key gone — the migration runs exactly once.
        XCTAssertNil(defaults.object(forKey: "rororo.launch.lowResourceMode"))
    }

    func testMigration_LegacyLowResourceModeTrue_PersistsAsPreset() {
        defaults.set(true, forKey: "rororo.launch.lowResourceMode")
        _ = LaunchSettingsStore(defaults: defaults)

        // A second instance reads the migrated activePreset key, not the
        // (now-removed) legacy bool.
        let reborn = LaunchSettingsStore(defaults: defaults)
        XCTAssertEqual(reborn.activePreset, .lowResource)
    }

    func testMigration_LegacyLowResourceModeFalse_BecomesNilPreset() {
        defaults.set(false, forKey: "rororo.launch.lowResourceMode")

        let store = LaunchSettingsStore(defaults: defaults)
        XCTAssertNil(store.activePreset)
    }

    func testMigration_NoLegacyKey_DefaultsToNilPreset() {
        // Fresh install — neither key set.
        let store = LaunchSettingsStore(defaults: defaults)
        XCTAssertNil(store.activePreset)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -only-testing:ROROROTests/LaunchSettingsStoreTests`
Expected: FAIL — compile error, `value of type 'LaunchSettingsStore' has no member 'activePreset'` / `setActivePreset`.

- [ ] **Step 3: Write the implementation** — four edits to `LaunchSettingsStore.swift`.

**Edit 3a** — replace the `lowResourceMode` property declaration (the `@Published` block with the ADR 0006 comment) with:

```swift
    /// The active FFlag preset (ADR 0011), or nil for "no preset — only
    /// the user's `fflags` overrides apply." Replaces the pre-0011
    /// `lowResourceMode: Bool` toggle. At launch FFlagPresetLibrary
    /// .effectiveFlags merges the preset's bundle with `fflags`; user
    /// values win on overlap. Hyperion may silently no-op some bundle
    /// entries — bench actual deltas before trusting.
    @Published public private(set) var activePreset: FFlagPresetID?
```

**Edit 3b** — replace the `lowResourceMode` line in `init` (currently `self.lowResourceMode = defaults.bool(forKey: Keys.lowResourceMode)`) with the migration block. The block must sit before the `startScreenSize` cleanup line:

```swift
        // Migrate the legacy `lowResourceMode` bool → `activePreset` enum
        // (ADR 0011). A user who had low-resource mode ON keeps it as
        // activePreset == .lowResource; the old key is cleared so the
        // migration runs exactly once. If the new key is already present,
        // it wins and no migration is needed.
        if let raw = defaults.string(forKey: Keys.activePreset),
           let decoded = FFlagPresetID(rawValue: raw) {
            self.activePreset = decoded
        } else if defaults.bool(forKey: Keys.lowResourceMode) {
            self.activePreset = .lowResource
            defaults.set(FFlagPresetID.lowResource.rawValue, forKey: Keys.activePreset)
            defaults.removeObject(forKey: Keys.lowResourceMode)
        } else {
            self.activePreset = nil
            defaults.removeObject(forKey: Keys.lowResourceMode)
        }
```

**Edit 3c** — replace the `setLowResourceMode(_:)` method with:

```swift
    /// Set the active FFlag preset (ADR 0011). Persisted across launches.
    /// At launch FFlagPresetLibrary.effectiveFlags merges the preset's
    /// bundle with the user's `fflags` overrides — user values win on
    /// overlap. Pass nil to clear the preset.
    public func setActivePreset(_ id: FFlagPresetID?) {
        activePreset = id
        if let id {
            defaults.set(id.rawValue, forKey: Keys.activePreset)
        } else {
            defaults.removeObject(forKey: Keys.activePreset)
        }
    }
```

**Edit 3d** — in the `Keys` enum, replace `static let lowResourceMode = "rororo.launch.lowResourceMode"` with:

```swift
        static let activePreset = "rororo.launch.activePreset"
        // Legacy — read once in `init` for the ADR 0011 migration, then removed.
        static let lowResourceMode = "rororo.launch.lowResourceMode"
```

**Edit 3e** — replace the `snapshot()` method and `Snapshot` struct:

```swift
    /// Snapshot of current settings — used by the launcher to apply at
    /// launch time without holding a reference to the store on a non-main
    /// actor.
    public func snapshot() -> Snapshot {
        Snapshot(framerateCap: framerateCap, fflags: fflags, activePreset: activePreset)
    }

    public struct Snapshot: Sendable, Equatable {
        public let framerateCap: Int?
        public let fflags: [String: AnyCodableValue]
        public let activePreset: FFlagPresetID?
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -only-testing:ROROROTests/LaunchSettingsStoreTests`
Expected: FAIL — `RobloxLauncher.swift` and `LastAppliedFFlagsStore.swift` and `DiagnosticsView.swift` still reference `snapshot.lowResourceMode` / `Snapshot(... lowResourceMode:)`. This is expected: Tasks 6, 7, and 10 fix those call sites. The `LaunchSettingsStoreTests` themselves are correct; the project just won't link yet. **Do not commit a broken build** — proceed straight to Task 6; Tasks 5-7 land as a coordinated set.

- [ ] **Step 5: Stage (do not commit yet)**

```bash
git add App/RORORO/Domain/LaunchSettingsStore.swift App/ROROROTests/LaunchSettingsStoreTests.swift
```

The commit happens at the end of Task 7, once the build is green again. Tasks 5-7 are a single coordinated `Snapshot`-shape change — committing 5 alone would leave `main`-quality history with a broken build.

---

### Task 6: Swap `LastAppliedFFlagsStore.Snapshot` to `activePreset`

**Files:**
- Modify: `App/RORORO/Domain/LastAppliedFFlagsStore.swift`
- Test: `App/ROROROTests/LastAppliedFFlagsStoreTests.swift` (new file)

- [ ] **Step 1: Write the failing test**

```swift
// LastAppliedFFlagsStoreTests.swift
// Domain — last-launch FFlag snapshot persistence, including ADR 0011's
// activePreset field swap and tolerant decode of pre-ADR-0011 records.

import XCTest
@testable import RORORO

@MainActor
final class LastAppliedFFlagsStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "rororo-last-fflags-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func testRecord_PersistsActivePresetAcrossInstances() {
        let store = LastAppliedFFlagsStore(defaults: defaults)
        let snap = LastAppliedFFlagsStore.Snapshot(
            appliedAt: Date(timeIntervalSince1970: 1_700_000_000),
            activePreset: .performance,
            flags: ["FFlagDisablePostFx": .bool(true)],
            outcome: "createdFresh"
        )
        store.record(snap)

        let reborn = LastAppliedFFlagsStore(defaults: defaults)
        XCTAssertEqual(reborn.lastSnapshot, snap)
        XCTAssertEqual(reborn.lastSnapshot?.activePreset, .performance)
    }

    func testRecord_NilActivePreset_RoundTrips() {
        let store = LastAppliedFFlagsStore(defaults: defaults)
        let snap = LastAppliedFFlagsStore.Snapshot(
            appliedAt: Date(timeIntervalSince1970: 1_700_000_000),
            activePreset: nil,
            flags: [:],
            outcome: "createdFresh"
        )
        store.record(snap)

        let reborn = LastAppliedFFlagsStore(defaults: defaults)
        XCTAssertNotNil(reborn.lastSnapshot)
        XCTAssertNil(reborn.lastSnapshot?.activePreset)
    }

    func testDecode_LegacyPreADR0011Record_DecodesWithNilActivePreset() throws {
        // A snapshot persisted before ADR 0011 carries `lowResourceMode`
        // (Bool) and no `activePreset`. The new optional field decodes to
        // nil via decodeIfPresent; the stale `lowResourceMode` key is
        // ignored. No crash, no data loss beyond the (non-load-bearing)
        // preset name. `appliedAt` is ISO8601 — the store's decoder uses
        // `.iso8601`.
        let legacyJSON = """
        {
          "appliedAt": "2023-11-14T22:13:20Z",
          "lowResourceMode": true,
          "flags": { "FFlagDisablePostFx": true },
          "outcome": "createdFresh"
        }
        """.data(using: .utf8)!
        defaults.set(legacyJSON, forKey: "rororo.diagnostics.lastFFlagSnapshot")

        let store = LastAppliedFFlagsStore(defaults: defaults)
        XCTAssertNotNil(store.lastSnapshot, "Legacy record should still decode")
        XCTAssertNil(store.lastSnapshot?.activePreset)
        XCTAssertEqual(store.lastSnapshot?.outcome, "createdFresh")
    }
}
```

- [ ] **Step 2: Regenerate project and run the test to verify it fails**

Run: `xcodegen generate --spec App/project.yml`
Then: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -only-testing:ROROROTests/LastAppliedFFlagsStoreTests`
Expected: FAIL — compile error, `Snapshot` has no `activePreset` parameter.

- [ ] **Step 3: Write the implementation** — replace the `Snapshot` struct in `LastAppliedFFlagsStore.swift`:

```swift
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
```

Also update the file-header comment line `"... and was the low-resource bundle folded in?"` to `"... and which preset was folded in?"`.

- [ ] **Step 4: Regenerate project and run the test to verify it passes**

Run: `xcodegen generate --spec App/project.yml`
Then: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -only-testing:ROROROTests/LastAppliedFFlagsStoreTests`
Expected: FAIL still — `RobloxLauncher.swift` and `DiagnosticsView.swift` haven't been updated. Expected; Task 7 + Task 10 fix them. The new test file itself is correct.

- [ ] **Step 5: Stage (do not commit yet)**

```bash
git add App/RORORO/Domain/LastAppliedFFlagsStore.swift App/ROROROTests/LastAppliedFFlagsStoreTests.swift
```

Commit lands at the end of Task 7.

---

### Task 7: Route `RobloxLauncher.applyLaunchSettings` through `FFlagPresetLibrary`

**Files:**
- Modify: `App/RORORO/Domain/RobloxLauncher.swift`
- Modify: `App/RORORO/Domain/LowResourceFFlags.swift` (remove the now-dead `merged(into:)`)
- Modify: `App/ROROROTests/LowResourceFFlagsTests.swift` (drop the merge tests; the merge is now covered by `FFlagPresetLibraryTests`)

- [ ] **Step 1: Confirm `LowResourceFFlags.merged` has no other callers**

Run: `grep -rn "LowResourceFFlags.merged" App/`
Expected: exactly two hits — `App/RORORO/Domain/RobloxLauncher.swift` and `App/ROROROTests/LowResourceFFlagsTests.swift`. If anything else appears, stop and reconcile before proceeding.

- [ ] **Step 2: Update `RobloxLauncher.swift`** — in `applyLaunchSettings(snapshot:effectiveCap:)`, replace the effective-flags block (from `let effectiveFlags = snapshot.lowResourceMode` through the end of the `if !effectiveFlags.isEmpty { ... }` block) with:

```swift
        // Compute the effective fflag set: the active preset's bundle
        // (empty when no preset) merged with user-set fflags. User-set
        // values overlay the preset so explicit overrides win.
        let effectiveFlags = FFlagPresetLibrary.effectiveFlags(
            for: snapshot.activePreset,
            userOverrides: snapshot.fflags
        )
        if !effectiveFlags.isEmpty {
            let payload: [String: Any] = effectiveFlags.mapValues { $0.jsonObject }
            do {
                let outcome = try ClientSettingsWriter.write(flags: payload)
                if let preset = snapshot.activePreset {
                    NSLog("[RORORO] launch: FFlag preset '\(preset.rawValue)' active (\(effectiveFlags.count) fflags written)")
                }
                let recorded = LastAppliedFFlagsStore.Snapshot(
                    appliedAt: Date(),
                    activePreset: snapshot.activePreset,
                    flags: effectiveFlags,
                    outcome: String(describing: outcome)
                )
                Task { @MainActor in
                    LastAppliedFFlagsStore.shared.record(recorded)
                }
            } catch {
                NSLog("[RORORO] ClientSettingsWriter failed: \(error)")
            }
        }
```

Also update the doc comment on `applyGlobalLaunchSettings` — change `"global FFlag bundle (low-resource + user-set)"` to `"global FFlag set (active preset + user-set overrides)"`.

- [ ] **Step 3: Remove the dead `merged(into:)` from `LowResourceFFlags.swift`** — delete the `merged(into:)` method and its doc comment (the `/// Merge bundle into userFlags...` block through the closing brace). Leave the `bundle` constant and the file header untouched.

- [ ] **Step 4: Trim `LowResourceFFlagsTests.swift`** — delete the four `testMerge_*` methods and the `// MARK: - merge` marker. Keep both `testBundle_*` methods and the `// MARK: - bundle invariants` marker. Update the file-header comment to: `// Domain — verifies the LowResourceFFlags bundle invariants. The merge // logic moved to FFlagPresetLibrary (ADR 0011); see FFlagPresetLibraryTests.`

- [ ] **Step 5: Regenerate project and run the affected suites**

Run: `xcodegen generate --spec App/project.yml`
Then: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -only-testing:ROROROTests/LowResourceFFlagsTests -only-testing:ROROROTests/FFlagPresetLibraryTests -only-testing:ROROROTests/LaunchSettingsStoreTests -only-testing:ROROROTests/LastAppliedFFlagsStoreTests`
Expected: PASS — the build links again and all four suites are green. (`RobloxLauncher.applyLaunchSettings` does real disk I/O and has no unit test; its merge logic is now covered by `FFlagPresetLibraryTests`. `DiagnosticsView` still references the old field — that's a UI file, fixed in Task 10; SwiftUI view code compiles against `activePreset` only after Task 10, so if the build still fails here it will be solely in `DiagnosticsView.swift` — that is acceptable to carry into Task 10 since Tasks 8-10 are all UI. If you prefer a green build at this commit, do Task 10's edit now and fold it in.)

> **Build-green checkpoint:** if the build is NOT fully green because of `DiagnosticsView.swift`, jump to Task 10, apply its edits, regenerate, and confirm the full project compiles before the Task 7 commit. The commit below must represent a compiling tree.

- [ ] **Step 6: Commit Tasks 5-7 (and 10 if folded in) as the coordinated `Snapshot` change**

```bash
git add App/RORORO/Domain/RobloxLauncher.swift App/RORORO/Domain/LowResourceFFlags.swift App/ROROROTests/LowResourceFFlagsTests.swift
# (LaunchSettingsStore + LastAppliedFFlagsStore + their tests were staged in Tasks 5-6)
git commit -m "refactor(fflags): migrate launch settings to activePreset + FFlagPresetLibrary

Swaps LaunchSettingsStore.lowResourceMode (Bool) for activePreset
(FFlagPresetID?) with a one-time UserDefaults migration, generalizes the
launch-time merge into FFlagPresetLibrary.effectiveFlags, and updates the
LastAppliedFFlagsStore snapshot + RobloxLauncher call site to match.
ADR 0011."
```

---

### Task 8: `FFlagsSheet` editor UI

**Files:**
- Create: `App/RORORO/UI/FFlagsSheet.swift`
- Test: `App/ROROROTests/FFlagsSheetTests.swift`

The view follows the project's untested-view pattern, but its editor model — the pure `rawValue ↔ AnyCodableValue` translation — is `static` and fully unit-tested.

- [ ] **Step 1: Write the failing test**

```swift
// FFlagsSheetTests.swift
// UI — the FFlagsSheet view itself follows the project's untested-view
// pattern, but its editor model (the pure rawValue <-> AnyCodableValue
// translation) is logic worth locking down.

import XCTest
@testable import RORORO

final class FFlagsSheetTests: XCTestCase {

    func testRowsFromStore_MapsEachTypeToRawText() {
        let rows = FFlagsSheet.rowsFromStore([
            "FFlagB": .bool(true),
            "DFIntI": .int(7),
            "DFNumD": .double(1.5),
            "FStringS": .string("metal"),
        ])
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0) })
        XCTAssertEqual(byKey["FFlagB"]?.type, .bool)
        XCTAssertEqual(byKey["FFlagB"]?.rawValue, "true")
        XCTAssertEqual(byKey["DFIntI"]?.type, .int)
        XCTAssertEqual(byKey["DFIntI"]?.rawValue, "7")
        XCTAssertEqual(byKey["DFNumD"]?.type, .double)
        XCTAssertEqual(byKey["FStringS"]?.type, .string)
        XCTAssertEqual(byKey["FStringS"]?.rawValue, "metal")
    }

    func testRowsFromStore_SortedByKey() {
        let rows = FFlagsSheet.rowsFromStore(["ZFlag": .bool(true), "AFlag": .bool(false)])
        XCTAssertEqual(rows.map(\.key), ["AFlag", "ZFlag"])
    }

    func testStoreFromRows_RoundTripsValidRows() {
        let original: [String: AnyCodableValue] = [
            "FFlagB": .bool(false),
            "DFIntI": .int(42),
        ]
        let rebuilt = FFlagsSheet.storeFromRows(FFlagsSheet.rowsFromStore(original))
        XCTAssertEqual(rebuilt, original)
    }

    func testStoreFromRows_DropsEmptyKey() {
        let rows = [FFlagsSheet.EditorRow(key: "", type: .bool, rawValue: "true")]
        XCTAssertTrue(FFlagsSheet.storeFromRows(rows).isEmpty)
    }

    func testStoreFromRows_DropsUnparseableValue() {
        let rows = [FFlagsSheet.EditorRow(key: "DFIntI", type: .int, rawValue: "not-a-number")]
        XCTAssertTrue(FFlagsSheet.storeFromRows(rows).isEmpty)
    }

    func testStoreFromRows_DuplicateKey_LastWins() {
        let rows = [
            FFlagsSheet.EditorRow(key: "FFlagB", type: .bool, rawValue: "true"),
            FFlagsSheet.EditorRow(key: "FFlagB", type: .bool, rawValue: "false"),
        ]
        XCTAssertEqual(FFlagsSheet.storeFromRows(rows), ["FFlagB": .bool(false)])
    }

    func testParsedValue_BoolRejectsNonBoolText() {
        let row = FFlagsSheet.EditorRow(key: "FFlagB", type: .bool, rawValue: "yes")
        XCTAssertNil(FFlagsSheet.parsedValue(for: row))
    }

    func testParseError_EmptyKey_ReportsError() {
        let row = FFlagsSheet.EditorRow(key: "", type: .string, rawValue: "x")
        XCTAssertEqual(FFlagsSheet.parseError(for: row), "Flag name can't be empty.")
    }

    func testParseError_ValidRow_ReturnsNil() {
        let row = FFlagsSheet.EditorRow(key: "FFlagB", type: .bool, rawValue: "true")
        XCTAssertNil(FFlagsSheet.parseError(for: row))
    }

    func testParseError_BadInt_ReportsError() {
        let row = FFlagsSheet.EditorRow(key: "DFIntI", type: .int, rawValue: "1.5")
        XCTAssertEqual(FFlagsSheet.parseError(for: row), "Not a whole number.")
    }
}
```

- [ ] **Step 2: Regenerate project and run the test to verify it fails**

Run: `xcodegen generate --spec App/project.yml`
Then: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -only-testing:ROROROTests/FFlagsSheetTests`
Expected: FAIL — `cannot find 'FFlagsSheet' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// FFlagsSheet.swift
// UI — the FFlags editor sheet (ADR 0011). Stacked layout: a preset
// picker on top (None + every FFlagPresetLibrary preset), an arbitrary
// key/value override editor below. Writes through to
// LaunchSettingsStore.activePreset + .fflags.
//
// Scope honesty: the subtitle says "Global" because the write surface
// (ClientAppSettings.json) is one file every Roblox instance reads —
// there is no per-account FFlag path (ADR 0002). Never reword this to
// imply per-instance behavior.
//
// Editor model: LaunchSettingsStore.fflags is an unordered dict; the
// sheet keeps an ordered [EditorRow] for stable identity while typing
// and commits parsed rows back to the store on every edit. Rows that
// don't parse (e.g. "abc" typed into an Int) stay visible with an inline
// error and are simply excluded from the committed dict.

import SwiftUI

struct FFlagsSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var launchSettings = LaunchSettingsStore.shared

    @State private var rows: [EditorRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    presetSection
                    Divider()
                    overridesSection
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.lg)
            }
            Divider()
            footer
        }
        .frame(minWidth: 540, minHeight: 520, idealHeight: 620)
        .background(Theme.Color.bgPage)
        .onAppear { rows = Self.rowsFromStore(launchSettings.fflags) }
    }

    // MARK: - Header / footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("FFlags")
                .font(Theme.Font.heading1)
                .foregroundStyle(Theme.Color.fg1)
            Text("Global — applies to every Roblox instance at launch.")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg3)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.md)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { isPresented = false }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.Color.productTeal)
        }
        .padding(Theme.Spacing.lg)
    }

    // MARK: - Preset section

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("PRESET")
                .font(Theme.Font.monoMicro)
                .foregroundStyle(Theme.Color.fg3)
                .tracking(1.4)
            HStack(spacing: Theme.Spacing.sm) {
                presetCard(
                    title: "None",
                    summary: "Only your overrides below",
                    isActive: launchSettings.activePreset == nil,
                    select: { launchSettings.setActivePreset(nil) }
                )
                ForEach(FFlagPresetLibrary.all) { preset in
                    presetCard(
                        title: preset.displayName,
                        summary: preset.summary,
                        isActive: launchSettings.activePreset == preset.id,
                        select: { launchSettings.setActivePreset(preset.id) }
                    )
                }
            }
        }
    }

    private func presetCard(
        title: String,
        summary: String,
        isActive: Bool,
        select: @escaping () -> Void
    ) -> some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(isActive ? Theme.Color.brandCyan : Theme.Color.fg1)
                Text(summary)
                    .font(Theme.Font.monoMicro)
                    .foregroundStyle(Theme.Color.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
            .padding(Theme.Spacing.sm)
            .background(Theme.Color.bgSurface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(
                        isActive ? Theme.Color.brandCyan : Theme.Color.bgRaised,
                        lineWidth: isActive ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Overrides section

    private var overridesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("YOUR OVERRIDES")
                    .font(Theme.Font.monoMicro)
                    .foregroundStyle(Theme.Color.fg3)
                    .tracking(1.4)
                Spacer()
                Button {
                    rows.append(EditorRow(key: "", type: .bool, rawValue: "true"))
                } label: {
                    Label("Add flag", systemImage: "plus")
                        .font(Theme.Font.bodySmall)
                }
                .buttonStyle(.bordered)
                .tint(Theme.Color.productTeal)
            }

            if rows.isEmpty {
                Text("No overrides. Pick a preset above, or add a flag to set one yourself. Overrides win over the preset on any key they share.")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg3)
            } else {
                ForEach($rows) { $row in
                    overrideRow($row)
                }
            }
        }
    }

    private func overrideRow(_ row: Binding<EditorRow>) -> some View {
        let risk = RiskyFFlagPatterns.risk(for: row.wrappedValue.key)
        let parseError = Self.parseError(for: row.wrappedValue)
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.sm) {
                TextField("FFlagName", text: row.key)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.mono)
                    .onChange(of: row.wrappedValue.key) { _, _ in commit() }

                TextField("value", text: row.rawValue)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.mono)
                    .frame(width: 88)
                    .onChange(of: row.wrappedValue.rawValue) { _, _ in commit() }

                Picker("", selection: row.type) {
                    ForEach(EditorRow.ValueType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .labelsHidden()
                .frame(width: 96)
                .onChange(of: row.wrappedValue.type) { _, _ in commit() }

                if let risk {
                    Text("⚠ \(risk.rawValue)")
                        .font(Theme.Font.monoMicro)
                        .foregroundStyle(Theme.Color.stateWarn)
                        .help("This flag name matches a known-risky pattern (\(risk.rawValue)). Some risky flags can be bannable in certain games — see ADR 0006. Saved anyway; your call.")
                }

                Button {
                    let id = row.wrappedValue.id
                    rows.removeAll { $0.id == id }
                    commit()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Color.fg3)
                }
                .buttonStyle(.plain)
            }
            if let parseError {
                Text(parseError)
                    .font(Theme.Font.monoMicro)
                    .foregroundStyle(Theme.Color.stateDanger)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    // MARK: - Commit

    private func commit() {
        launchSettings.setFFlags(Self.storeFromRows(rows))
    }

    // MARK: - Editor model (pure — unit-tested in FFlagsSheetTests)

    struct EditorRow: Identifiable {
        let id = UUID()
        var key: String
        var type: ValueType
        var rawValue: String

        enum ValueType: String, CaseIterable {
            case bool = "Bool"
            case int = "Int"
            case double = "Double"
            case string = "String"
        }
    }

    /// Build editor rows from the persisted dict, sorted by key for a
    /// stable display order (the dict itself is unordered).
    static func rowsFromStore(_ flags: [String: AnyCodableValue]) -> [EditorRow] {
        flags.sorted { $0.key < $1.key }.map { key, value in
            switch value {
            case .bool(let b):   return EditorRow(key: key, type: .bool,   rawValue: b ? "true" : "false")
            case .int(let i):    return EditorRow(key: key, type: .int,    rawValue: String(i))
            case .double(let d): return EditorRow(key: key, type: .double, rawValue: String(d))
            case .string(let s): return EditorRow(key: key, type: .string, rawValue: s)
            }
        }
    }

    /// Parse editor rows back into the persisted dict. Rows with an empty
    /// key or an unparseable value are dropped (they stay in the UI with
    /// an inline error via `parseError`). On a duplicate key the last row
    /// wins — consistent with "the dict is keyed."
    static func storeFromRows(_ rows: [EditorRow]) -> [String: AnyCodableValue] {
        var out: [String: AnyCodableValue] = [:]
        for row in rows {
            guard !row.key.isEmpty, let value = parsedValue(for: row) else { continue }
            out[row.key] = value
        }
        return out
    }

    /// The parsed AnyCodableValue for a row, or nil when the raw text
    /// doesn't fit the chosen type.
    static func parsedValue(for row: EditorRow) -> AnyCodableValue? {
        switch row.type {
        case .bool:
            switch row.rawValue.lowercased() {
            case "true":  return .bool(true)
            case "false": return .bool(false)
            default:      return nil
            }
        case .int:
            return Int(row.rawValue).map(AnyCodableValue.int)
        case .double:
            return Double(row.rawValue).map(AnyCodableValue.double)
        case .string:
            return .string(row.rawValue)
        }
    }

    /// Inline validation message for a row, or nil when the row is valid.
    static func parseError(for row: EditorRow) -> String? {
        if row.key.isEmpty { return "Flag name can't be empty." }
        if parsedValue(for: row) == nil {
            switch row.type {
            case .bool:   return "Bool must be \"true\" or \"false\"."
            case .int:    return "Not a whole number."
            case .double: return "Not a number."
            case .string: return nil
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Regenerate project and run the test to verify it passes**

Run: `xcodegen generate --spec App/project.yml`
Then: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -only-testing:ROROROTests/FFlagsSheetTests`
Expected: PASS — 10 tests.

- [ ] **Step 5: Commit**

```bash
git add App/RORORO/UI/FFlagsSheet.swift App/ROROROTests/FFlagsSheetTests.swift
git commit -m "feat(fflags): add FFlagsSheet editor UI"
```

---

### Task 9: Wire the FFlags sheet into `SettingsView`

**Files:**
- Modify: `App/RORORO/UI/SettingsView.swift`

`SettingsView` presents the FFlags sheet itself via `.sheet`. (The design spec said "wire the `.sheet` presentation"; it lands in `SettingsView` rather than `ContentView` because the button lives in `SettingsView` and pushing presentation state up out of a sheet is awkward. Sheet-on-sheet works on macOS 14 — flagged as a manual-verification watch-point.)

- [ ] **Step 1: Remove the `lowResourceModeEnabled` state**

Delete the line `@State private var lowResourceModeEnabled: Bool` from the property block, and delete the line `_lowResourceModeEnabled = State(initialValue: LaunchSettingsStore.shared.lowResourceMode)` from `init()`.

- [ ] **Step 2: Add the `showFFlags` state** — add to the property block, next to `dangerZoneVisible`:

```swift
    @State private var showFFlags = false
```

- [ ] **Step 3: Replace the "Low-resource mode" section** — replace the entire `section("Low-resource mode") { ... }` block with:

```swift
                    section("FFlags") {
                        Button {
                            showFFlags = true
                        } label: {
                            Label("Open FFlags editor…", systemImage: "flag.2.crossed")
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.Color.productTeal)
                        Text(fflagsSummary)
                            .font(Theme.Font.bodySmall)
                            .foregroundStyle(Theme.Color.fg3)
                    }
```

- [ ] **Step 4: Add the `fflagsSummary` computed property** — add inside the struct, just above the `section(_:content:)` helper:

```swift
    /// One-line state summary for the FFlags Settings row. `launchSettings`
    /// is already an @ObservedObject, so this recomputes when the preset
    /// or overrides change.
    private var fflagsSummary: String {
        let presetName: String
        if let id = launchSettings.activePreset,
           let preset = FFlagPresetLibrary.preset(id) {
            presetName = preset.displayName
        } else {
            presetName = "None"
        }
        let count = launchSettings.fflags.count
        let overrides = count == 1 ? "1 override" : "\(count) overrides"
        return "Preset: \(presetName) · \(overrides). Global — every Roblox instance, applied at launch."
    }
```

- [ ] **Step 5: Present the sheet** — add a `.sheet` modifier on the outermost `VStack` in `body`, directly after the existing `.background(Theme.Color.bgPage)` modifier:

```swift
        .sheet(isPresented: $showFFlags) {
            FFlagsSheet(isPresented: $showFFlags)
        }
```

- [ ] **Step 6: Regenerate project and build**

Run: `xcodegen generate --spec App/project.yml`
Then: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO build -destination 'platform=macOS,arch=x86_64'`
Expected: BUILD SUCCEEDED. (`SettingsView` is an untested view — no test class. The editor logic it touches is covered by `FFlagsSheetTests` + `LaunchSettingsStoreTests`.)

- [ ] **Step 7: Manual verification**

Launch the app (`xcodebuild ... build` output, or open in Xcode and run). Open Settings → confirm the "FFlags" section shows the button + summary line, the button opens the FFlags sheet, picking a preset highlights its card, "Add flag" adds an editable row, and "Done" closes back to Settings.

- [ ] **Step 8: Commit**

```bash
git add App/RORORO/UI/SettingsView.swift
git commit -m "feat(fflags): replace Settings low-resource toggle with FFlags editor button"
```

---

### Task 10: Show the active preset in `DiagnosticsView`

**Files:**
- Modify: `App/RORORO/UI/DiagnosticsView.swift`

**Note:** if you already applied this edit during Task 7's build-green checkpoint, this task is just the verification + commit — the commit moves here, separate from the Task 7 commit's staged files.

- [ ] **Step 1: Add the `presetLabel` helper** — add inside the struct, just above the `formattedTimestamp(_:)` helper:

```swift
    private func presetLabel(_ id: FFlagPresetID?) -> String {
        guard let id else { return "None" }
        return FFlagPresetLibrary.preset(id)?.displayName ?? id.rawValue
    }
```

- [ ] **Step 2: Update `fflagsSection`** — replace the `row("Low-resource mode", ...)` line with:

```swift
                row("Active preset", value: presetLabel(snap.activePreset),
                    color: snap.activePreset == nil ? Theme.Color.fg3 : Theme.Color.stateOk)
```

And replace the empty-state `Text(...)` (the `else` branch, "No FFlags written yet...") with:

```swift
                Text("No FFlags written yet. Launch an account with a preset selected (or any user-set FFlags) and the snapshot lands here.")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg3)
```

- [ ] **Step 3: Update `copyAll()`** — replace the line `lines.append("Low-resource mode: \(snap.lowResourceMode ? "ON" : "OFF")")` with:

```swift
            lines.append("Active preset: \(presetLabel(snap.activePreset))")
```

- [ ] **Step 4: Regenerate project and build**

Run: `xcodegen generate --spec App/project.yml`
Then: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO build -destination 'platform=macOS,arch=x86_64'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add App/RORORO/UI/DiagnosticsView.swift
git commit -m "refactor(fflags): show active preset in DiagnosticsView"
```

---

### Task 11: ADR 0011 + full-suite verification

**Files:**
- Create: `docs/decisions/0011-fflag-preset-library.md`

- [ ] **Step 1: Write the ADR**

```markdown
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
- `PerformanceFFlags` needs a runtime bench (same protocol as ADR 0006)
  before its real deltas are known.

## Implementation map

See `docs/superpowers/plans/2026-05-14-fflag-preset-library.md` for the
task-by-task plan and the full file-level change list.
```

- [ ] **Step 2: Regenerate the project and run the FULL suite**

Run: `xcodegen generate --spec App/project.yml`
Then: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64'`
Expected: TEST SUCCEEDED — every suite green, including the pre-existing ones. If any pre-existing suite fails, confirm it fails on `main` too before treating it as a regression (the CI keychain suites are opt-in — see recent commit history).

- [ ] **Step 3: Commit**

```bash
git add docs/decisions/0011-fflag-preset-library.md
git commit -m "docs(fflags): ADR 0011 — FFlag preset library + editor"
```

- [ ] **Step 4: Hand back to the orchestrator** for the 626Labs Dashboard decision log (ADR 0011 is a schema/data-model change — log-worthy per CLAUDE.md) and the PR.

---

## Self-Review

**1. Spec coverage** — every spec section maps to a task:
- Preset library (low-resource + Performance) → Tasks 2, 3
- Arbitrary editor → Task 8
- Non-blocking safety badge → Tasks 4, 8
- Global-scope honesty → Task 8 (subtitle), Task 9 (summary line)
- `activePreset` data model + migration → Task 5
- `FFlagPresetLibrary` + generalized merge → Tasks 3, 7
- UI layout (stacked sheet) → Task 8
- `SettingsView` button replaces toggle → Task 9
- `LastAppliedFFlagsStore` + `DiagnosticsView` updates → Tasks 6, 10
- Testing (5 suites) → Tasks 1-8 each ship their suite
- ADR → Task 11
- File map → matches, with one refinement: the spec listed `ContentView.swift` as modified; the plan lands sheet presentation in `SettingsView` instead (Task 9 explains why). No `ContentView` change is needed.

**2. Placeholder scan** — no "TBD"/"TODO"/"handle edge cases"; every code step shows complete code; every command shows expected output.

**3. Type consistency** — checked across tasks: `FFlagPresetID` (`.lowResource`/`.performance`), `FFlagPreset(id:displayName:summary:bundle:)`, `FFlagPresetLibrary.all` / `.preset(_:)` / `.effectiveFlags(for:userOverrides:)`, `FFlagRiskCategory` (`.physics`/`.network`/`.simulation`), `RiskyFFlagPatterns.risk(for:)`, `LaunchSettingsStore.activePreset` / `.setActivePreset(_:)`, `Snapshot(framerateCap:fflags:activePreset:)`, `LastAppliedFFlagsStore.Snapshot(appliedAt:activePreset:flags:outcome:)`, `FFlagsSheet.EditorRow(key:type:rawValue:)` + `.rowsFromStore`/`.storeFromRows`/`.parsedValue(for:)`/`.parseError(for:)` — all names used consistently in every task that references them.

**Known watch-point (not a plan defect):** Tasks 5-7 are a coordinated `Snapshot`-shape change — the build is intentionally red between Task 5 and the Task 7 commit; the plan calls this out and commits only a compiling tree. Sheet-on-sheet presentation in Task 9 is flagged for manual verification.
