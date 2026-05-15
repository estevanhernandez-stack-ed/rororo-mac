# Framerate-Override Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make per-account framerate overrides not silent — fix the misleading Settings copy and add a divergence-only warn pill on the existing override badge.

**Architecture:** Pure divergence rule lives in a new Domain helper (`FramerateOverrideDivergence`). `AccountsListView` observes `LaunchSettingsStore.shared` and plumbs the global cap into each `AccountRow`; the row renders a warn pill when the override diverges, neutral subtle styling when it matches or there is no global. `SettingsView`'s Frame rate copy is rewritten to name the override mechanism instead of claiming "uniformly."

**Tech Stack:** Swift 5.9 / SwiftUI, XcodeGen (`App/project.yml` is source of truth; `.xcodeproj` is gitignored and regenerated), XCTest.

**Spec:** `docs/superpowers/specs/2026-05-14-framerate-override-visibility-design.md`

## Conventions used by every task

- **Regenerate the project after creating any new file** (folder globs):
  `xcodegen generate --spec App/project.yml`
- **Run one test class:**
  `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -only-testing:ROROROTests/<ClassName>`
- **Run the full suite (CI-equivalent — keychain skipped):**
  `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -skip-testing:ROROROTests/RororoKeychainTests -skip-testing:ROROROTests/RororoKeychainItemsTests -skip-testing:ROROROTests/RororoKeychainBootstrapTests`
- One conventional commit per task, scoped `(framerate-overrides)`.
- **Working directory is the worktree:** `/Users/estevanhernandez/projects/rororo-mac/.claude/worktrees/ux-polish+framerate-override-visibility/` — every command runs from there. Branch is `worktree-ux-polish+framerate-override-visibility`. Subagents inherit this cwd; do not `cd` elsewhere.

---

### Task 1: `FramerateOverrideDivergence` Domain helper + tests

**Files:**
- Create: `App/RORORO/Domain/FramerateOverrideDivergence.swift`
- Test: `App/ROROROTests/FramerateOverrideDivergenceTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// FramerateOverrideDivergenceTests.swift
import XCTest
@testable import RORORO

final class FramerateOverrideDivergenceTests: XCTestCase {

    func testDiverges_NoOverride_ReturnsFalse() {
        // No override at all — there is nothing to flag.
        XCTAssertFalse(FramerateOverrideDivergence.diverges(override: nil, global: 144))
    }

    func testDiverges_OverrideSetGlobalNil_ReturnsFalse() {
        // No global to compare against — the override is "your only opinion."
        XCTAssertFalse(FramerateOverrideDivergence.diverges(override: 20, global: nil))
    }

    func testDiverges_OverrideMatchesGlobal_ReturnsFalse() {
        // The override happens to match the global — applying it changes
        // nothing. No surprise to surface.
        XCTAssertFalse(FramerateOverrideDivergence.diverges(override: 20, global: 20))
    }

    func testDiverges_OverrideDiffersFromGlobal_ReturnsTrue() {
        // Override silently overrides the global on launch — this is the
        // trap the badge surfaces.
        XCTAssertTrue(FramerateOverrideDivergence.diverges(override: 20, global: 144))
    }
}
```

- [ ] **Step 2: Regenerate the project and run the test to verify it fails**

Run: `xcodegen generate --spec App/project.yml`
Then: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -only-testing:ROROROTests/FramerateOverrideDivergenceTests`
Expected: FAIL — compile error, `cannot find 'FramerateOverrideDivergence' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// FramerateOverrideDivergence.swift
// Domain — UI-visibility rule for per-account framerate overrides
// (ADR 0002). Pure: no SwiftUI dependency, no actor isolation. The UI
// (AccountsListView) calls `diverges(override:global:)` to choose between
// a warn-pill and the today's-subtle styling for the override badge.

import Foundation

public enum FramerateOverrideDivergence {

    /// True when a per-account framerate override should be flagged as a
    /// user-visible divergence from the global cap. Only true when the
    /// global is concretely set AND the override differs from it.
    ///
    /// - When `override` is nil, there is no override to flag → false.
    /// - When `global` is nil, the override is "your only opinion" — there
    ///   is nothing to diverge from → false.
    /// - When both are set and equal, the override is harmless (it would
    ///   apply the same value the global does) → false.
    /// - When both are set and differ, the override silently overrides
    ///   the global on launch — the trap to surface → true.
    public static func diverges(override: Int?, global: Int?) -> Bool {
        guard let override, let global else { return false }
        return override != global
    }
}
```

- [ ] **Step 4: Regenerate the project and run the test to verify it passes**

Run: `xcodegen generate --spec App/project.yml`
Then: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' -only-testing:ROROROTests/FramerateOverrideDivergenceTests`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add App/RORORO/Domain/FramerateOverrideDivergence.swift App/ROROROTests/FramerateOverrideDivergenceTests.swift
git commit -m "feat(framerate-overrides): add FramerateOverrideDivergence helper"
```

---

### Task 2: Settings copy fix

**Files:**
- Modify: `App/RORORO/UI/SettingsView.swift` (the Frame rate section's `Text` block, currently around lines 78-82)

This task has no unit test — `SettingsView` follows the project's untested-view pattern (matches `DiagnosticsView`, `AccountsListView`, etc.). Build-green is the verification; manual visual smoke check covers the copy itself in Task 4.

- [ ] **Step 1: Replace the conditional Text block** — replace this block in `SettingsView.swift`:

```swift
                        Text(framerateCapEnabled
                             ? "Roblox-wide cap. Every running instance is throttled at this rate uniformly — applied at next launch. Already-running instances keep their current cap until restart."
                             : "Default: Roblox uses its built-in 60 fps cap.")
                            .font(Theme.Font.bodySmall)
                            .foregroundStyle(Theme.Color.fg3)
```

with this single, honest line that names the per-account override mechanism (per the spec's "honest in both states" choice — flatten the conditional):

```swift
                        Text("Roblox-wide cap by default — per-account overrides (set on the account row) win when present. Applied at next launch; already-running instances keep their current cap until restart.")
                            .font(Theme.Font.bodySmall)
                            .foregroundStyle(Theme.Color.fg3)
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO build -destination 'platform=macOS,arch=x86_64' 2>&1 | grep -E "(BUILD SUCCEEDED|BUILD FAILED|error:)" | head -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/RORORO/UI/SettingsView.swift
git commit -m "polish(framerate-overrides): rewrite Settings copy to mention overrides"
```

---

### Task 3: AccountsListView — plumb global + warn-pill rendering

**Files:**
- Modify: `App/RORORO/UI/AccountsListView.swift` (three edit sites: outer struct property block, the `row(for:...)` AccountRow init call, and `AccountRow`'s property list + the existing badge block + a new private helper)

This task has no unit test — the plumbing + view changes follow the untested-view pattern. The pure logic underneath (the divergence rule) is fully covered by Task 1. Build-green is the verification; manual visual smoke check is in Task 4.

- [ ] **Step 1: Add `@ObservedObject launchSettings` to `AccountsListView`** — find this block at the top of the struct (around lines 13-19):

```swift
struct AccountsListView: View {
    @Binding var showAddAccount: Bool
    @Binding var showGames: Bool

    @State private var inFlightLaunchUserId: String?
```

Insert a new line between the `@Binding` block and the `@State` block:

```swift
struct AccountsListView: View {
    @Binding var showAddAccount: Bool
    @Binding var showGames: Bool

    @ObservedObject private var launchSettings = LaunchSettingsStore.shared

    @State private var inFlightLaunchUserId: String?
```

- [ ] **Step 2: Pass `globalFramerateCap` into `AccountRow` from `row(for:...)`** — find this call around lines 354-394:

```swift
        AccountRow(
            account: account,
            isLaunching: inFlightLaunchUserId == account.userId,
            defaultDisplayName: defaultName,
            favorites: favoriteStore.favorites,
            servers: serverStore.servers,
            existingGroups: existingGroups,
            onLaunchPrimary: { launchPrimary(account: account) },
```

Insert a new argument between `existingGroups` and `onLaunchPrimary`:

```swift
        AccountRow(
            account: account,
            isLaunching: inFlightLaunchUserId == account.userId,
            defaultDisplayName: defaultName,
            favorites: favoriteStore.favorites,
            servers: serverStore.servers,
            existingGroups: existingGroups,
            globalFramerateCap: launchSettings.framerateCap,
            onLaunchPrimary: { launchPrimary(account: account) },
```

- [ ] **Step 3: Add `globalFramerateCap` property to `AccountRow`** — find the property list at the top of the inner `private struct AccountRow: View` (around lines 577-593):

```swift
private struct AccountRow: View {
    let account: Account
    let isLaunching: Bool
    let defaultDisplayName: String?
    let favorites: [FavoriteGame]
    let servers: [SavedPrivateServer]
    let existingGroups: [String]
    let onLaunchPrimary: () -> Void
```

Insert a new property between `existingGroups` and `onLaunchPrimary`:

```swift
private struct AccountRow: View {
    let account: Account
    let isLaunching: Bool
    let defaultDisplayName: String?
    let favorites: [FavoriteGame]
    let servers: [SavedPrivateServer]
    let existingGroups: [String]
    let globalFramerateCap: Int?
    let onLaunchPrimary: () -> Void
```

- [ ] **Step 4: Replace the existing badge block with a call to the new helper** — find this block inside `splitLaunchButton` (around lines 662-676):

```swift
            // Per-account framerate override badge. Only rendered when
            // the account has an explicit override — accounts using the
            // global setting (or with no cap at all) get no badge, so
            // the row stays clean for users not engaged with per-account
            // throttling. Renders on the same gradient as the primary
            // button + chevron, distinguished by mono-micro size.
            if let cap = account.framerateCapOverride {
                Text("\(cap)FPS")
                    .font(Theme.Font.monoMicro)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .tracking(0.5)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .accessibilityLabel("Per-account framerate cap: \(cap) frames per second")
            }
```

Replace it with this divergence-driven dispatch into the new helper:

```swift
            // Per-account framerate override badge (ADR 0011 ux-polish).
            // FramerateOverrideDivergence picks the styling: warn pill
            // when the override diverges from the global (the trap), or
            // today's subtle in-button styling when the override matches
            // the global or no global is set.
            if let cap = account.framerateCapOverride {
                overrideBadge(cap: cap, global: globalFramerateCap)
            }
```

- [ ] **Step 5: Add the `overrideBadge` helper inside `AccountRow`** — find a private helper to insert above. The cleanest spot is just after `splitLaunchButton`'s closing brace and before `primaryLabel` (around line 765 in the pre-edit file). Insert this method:

```swift
    /// Per-account framerate override badge. Two visual states driven by
    /// FramerateOverrideDivergence:
    ///
    /// - **Warn pill** (amber background, dark text, ⚠ + cap value) when
    ///   the override diverges from the global. This is the trap to
    ///   surface — the user changed the global and the override silently
    ///   wins on launch.
    /// - **Subtle in-button text** (today's styling, preserved verbatim)
    ///   when the override matches the global or no global is set. No
    ///   nag when there is no real surprise.
    @ViewBuilder
    private func overrideBadge(cap: Int, global: Int?) -> some View {
        if let global, FramerateOverrideDivergence.diverges(override: cap, global: global) {
            // Warn pill — global is unwrapped here per the divergence rule.
            HStack(spacing: 4) {
                Text("⚠")
                Text("\(cap)")
            }
            .font(Theme.Font.monoMicro)
            .foregroundStyle(Theme.Color.bgPage)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.Color.stateWarn, in: RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .help("Per-account override: \(cap)fps. Global is \(global)fps.")
            .accessibilityLabel(
                "Per-account framerate cap override: \(cap) frames per second; differs from global setting"
            )
        } else {
            // Match or no global — keep today's subtle in-button styling.
            Text("\(cap)FPS")
                .font(Theme.Font.monoMicro)
                .foregroundStyle(Color.white.opacity(0.85))
                .tracking(0.5)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .accessibilityLabel("Per-account framerate cap: \(cap) frames per second")
        }
    }
```

- [ ] **Step 6: Build to verify**

Run: `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO build -destination 'platform=macOS,arch=x86_64' 2>&1 | grep -E "(BUILD SUCCEEDED|BUILD FAILED|error:)" | head -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add App/RORORO/UI/AccountsListView.swift
git commit -m "polish(framerate-overrides): warn-pill badge when override diverges from global"
```

---

### Task 4: Full-suite verification + smoke handoff

No code change. This task confirms the branch is fully green and hands back to the orchestrator for the manual smoke check + PR.

- [ ] **Step 1: Run the full test suite (CI-equivalent flags)**

Run:
```
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64' \
  -skip-testing:ROROROTests/RororoKeychainTests \
  -skip-testing:ROROROTests/RororoKeychainItemsTests \
  -skip-testing:ROROROTests/RororoKeychainBootstrapTests 2>&1 | grep -E "(Executed [0-9]+ tests|TEST FAILED|TEST SUCCEEDED|BUILD FAILED|error:)" | tail -5
```

Expected: `** TEST SUCCEEDED **`. The line count should report the previously-green totals plus the 4 new `FramerateOverrideDivergenceTests`.

- [ ] **Step 2: Hand back to the orchestrator** for the manual smoke check (the three render states — no-badge, neutral, warn — plus the Settings copy) and the PR.

---

## Self-Review

**1. Spec coverage** — every spec section maps to a task:

| Spec section | Task |
|---|---|
| `FramerateOverrideDivergence` Domain helper + 4 tests | Task 1 |
| Settings copy rewrite (flatten conditional) | Task 2 |
| `@ObservedObject launchSettings` plumbing | Task 3 (Step 1) |
| `globalFramerateCap` flow into `AccountRow` | Task 3 (Steps 2-3) |
| `overrideBadge(cap:global:)` helper with warn/neutral states | Task 3 (Steps 4-5) |
| Tooltip + accessibility label on warn pill | Task 3 (Step 5) |
| Manual visual check covers three render states | Task 4 |

No gaps.

**2. Placeholder scan** — no "TBD" / "TODO" / "handle edge cases"; every code step shows complete code; every command shows expected output.

**3. Type consistency** — checked across tasks: `FramerateOverrideDivergence.diverges(override:global:) -> Bool` (Task 1) is called identically in Task 3 (Step 5). `AccountRow` gains `globalFramerateCap: Int?` in Task 3 Step 3 and is passed `launchSettings.framerateCap` in Task 3 Step 2 (both `Int?`). The `overrideBadge(cap:global:)` signature in Step 5 matches the call site in Step 4. Theme tokens (`Theme.Color.stateWarn`, `Theme.Color.bgPage`, `Theme.Font.monoMicro`) verified against `App/RORORO/Theme/Theme.swift` from prior reads.
