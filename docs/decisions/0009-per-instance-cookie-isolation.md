# ADR 0009 — Per-instance cookie isolation via bundle ID rewrite + re-sign

**Date:** 2026-05-12
**Status:** Accepted (shipped on `fix/launcher-cookie-isolation`, commits `a395c62` → `c447ece`)
**Slope:** Cookie isolation — closes the long-latent multi-instance identity-collision bug
**Supersedes:** Plan v1 at `docs/superpowers/plans/2026-05-11-per-instance-cookie-isolation.md` (HOME-injection + direct binary spawn) — proven unworkable by Task 0 PoC; replaced with plan v2 in-place.

## Background

Multi-instance Roblox shipped on macOS in commit `e734409` (2026-05-07). The recipe — `cp -a /Applications/Roblox.app` to a per-instance dir, flip `LSMultipleInstancesProhibited=false`, `sem_unlink` the kernel singleton, `open -n -a` — got two concurrent Roblox windows on screen. What it did not solve was **session-identity isolation**.

The latent bug, observed by the user 2026-05-11 evening:

> "Two instances open, one took over the other — it tried to log back in as the second launched account when auto-rejoin fired."

Root cause: macOS keys cookies, NSUserDefaults, HTTPStorages, and WebKit storage by `CFBundleIdentifier`, not bundle path. All per-instance copies declared the same `CFBundleIdentifier = com.roblox.RobloxPlayer`, so all running instances shared:

```
~/Library/HTTPStorages/com.roblox.RobloxPlayer.binarycookies
~/Library/Preferences/com.roblox.RobloxPlayer.plist
~/Library/HTTPStorages/com.roblox.RobloxPlayer/
~/Library/WebKit/com.roblox.RobloxPlayer/
```

When the second account's engine wrote to `com.roblox.RobloxPlayer.binarycookies` after auth, it clobbered the first account's session cookie. When the first account's engine hit its ~20-minute idle-timeout auto-rejoin, it read the now-second-account cookie and "logged back in as" the second account, knocking the second account's real session off.

The bug has been latent across every multi-instance release. No prior tool in the public Mac multi-launcher space (Insadem's `multi-roblox-macos`, AppleBlox, `SomeRandomGuy45/MacBlox`) had named or fixed it. Symptom reports cluster under three folk-names — "Error 264 same account launched from different device," "teleport fails — thinks the same account joining the same server," "logged me out of both" — and tool maintainers had routed around them with constraint workarounds ("you have to join a game before opening a new instance, also you can't teleport" — AppleBlox issue #82) rather than diagnosing the storage-keyed-by-bundle-ID root cause.

## Decision 1 — Per-instance copies get a unique `CFBundleIdentifier`

**Decision:** Each per-instance Roblox bundle copy gets a unique `CFBundleIdentifier` derived from the launching account's stable Roblox `userId`:

```
com.626labs.RORORO.instance.uid<slug(userId)>
```

Slugification restricts to `[a-z0-9-]` (the reverse-DNS safe subset). `userId` is stable across renames; the bundle ID is therefore stable across launches of the same account. nil/empty/all-invalid slug falls back to a fresh UUID (rare external-URL-handoff path with no account context).

**Rationale:** Unique bundle IDs deliver per-instance storage isolation natively. macOS routes every bundle-ID-keyed write to a path that includes the bundle ID:

- `~/Library/HTTPStorages/com.626labs.RORORO.instance.uid<slug>.binarycookies`
- `~/Library/Preferences/com.626labs.RORORO.instance.uid<slug>.plist`
- `~/Library/HTTPStorages/com.626labs.RORORO.instance.uid<slug>/`
- `~/Library/WebKit/com.626labs.RORORO.instance.uid<slug>/`

Two accounts → two bundle IDs → two cookie jars. The collision cannot recur. No `$HOME` redirection needed. No `cfprefsd` workaround needed.

**Stable-per-account derivation matters** (not per-launch UUID). macOS TCC grants — local network, camera, microphone, accessibility — are keyed by bundle ID. A per-launch UUID would re-prompt the user for every Launch As. A stable-per-account slug prompts once per account and never again. `RunningAccountTracker.backfillFromRunningProcesses` also depends on stable IDs to match running pids back to accounts on cold-start.

**Consequences:**

- New helper `BundleIDRewriter` (Swift, in `Domain/`) handles the in-place plist edit + re-sign.
- `RobloxAppCopier.copyAppForInstance` takes an `accountSlug:` parameter and calls `BundleIDRewriter.rewrite` at the end of the copy. Threading: `RobloxLauncher` → `MultiInstanceCoordinator.handleIncomingURL(userId:)` → `LaunchRequest.userId` → `performLaunch(accountSlug:)` → `copyAppForInstance(accountSlug:)`.
- `RunningAccountTracker.backfillFromRunningProcesses` widened its bundleIdentifier prefix filter to recognize both `com.roblox.*` AND `com.626labs.RORORO.instance.*`. Without that widening, re-signed bundles are invisible to the tracker, the cycler has no pids to drive macros against, and the UI shows "no macro assigned" on every Launch As.

## Decision 2 — Re-sign the modified copy with ad-hoc `--deep`

**Decision:** After rewriting Info.plist, re-sign the bundle with:

```
codesign --force --deep --sign - <copy.app>
```

Ad-hoc identity (`-`), `--deep` re-signs every embedded binary. Tests use `--sign -` explicitly; production code defaults to `-` via `RobloxAppCopier.defaultSigningIdentity()`. The identity is parameterized for future override (e.g., a premium-signed-builds path), but the ad-hoc default is the working production recipe.

**Rationale:** The plist edit invalidates the bundle's cdhash; amfid refuses Hardened Runtime spawn under a broken signature. Re-signing recomputes the cdhash. Ad-hoc identity was the contested choice — see the prior-recipe-tried-and-failed history below — and was settled by the Task 4.5 PoC plus a population-level evidence sweep:

| Tool | Stack | Re-sign recipe | User base |
|---|---|---|---|
| **Nitrogen** (`JadXV/Nitrogen`) | Electron | `--force --deep --sign -` (no entitlements) | Thousands (active Discord-driven) |
| **Raptor-Manager** (`DollarNoob/Raptor-Manager`) | Tauri/Rust | `--force --entitlements ... -s -` (Delta sandboxed path only) | Active, MIT-licensed |
| **celestial-ui** (`imeowforcash/celestial-ui`) | Tauri/Rust | (no `codesign` at all — relies on `lsregister`) | Active product |

Three independently developed Mac multi-launchers converged on the same overall architecture (regex-rewrite CFBundleIdentifier per account, cookie isolated via macOS native storage routing). None of them adds `com.apple.security.cs.disable-library-validation`. Our prior recipe (no `--deep`, with the entitlement) was novel but failed when the signing identity dropped to ad-hoc because `codesign` bails on unsigned subcomponents (RORORO writes `ClientAppSettings.json` for FFlag injection into the bundle's `Contents/MacOS/ClientSettings/` — a file `cp -R` inherits but is not in Roblox's signed manifest).

**Consequences:**

- **No Developer ID cert required on end-user machines.** The runtime re-sign is ad-hoc, which works on any user's keychain. Distribution via the existing notarized RORORO.app + Sparkle delivers the cookie-isolation fix to every v0.6.1+ user without cert ceremony.
- **Hardened Runtime is dropped on the re-signed copy.** Ad-hoc with `--deep` strips the runtime flag from every binary in the bundle. The cookie-isolation goal does not require Hardened Runtime on Roblox's binary specifically — isolation comes from the bundle ID rewrite, which works regardless of signing identity. The parent app (RORORO.app itself) retains Hardened Runtime + notarization unchanged.
- **Roblox's Roblox-team signature is lost on every binary in the copy.** Library validation has nothing to enforce because everything's ad-hoc and self-consistent (no team mismatch can occur when there's no team anywhere). Hyperion / Roblox anti-cheat acceptance under this signature is established by Nitrogen's population-level evidence; the user-side ~10-minute play smoke at v0.7.0 is the prudent confirmation.

## Decision 3 — `RunningAccountTracker` widens its prefix filter

**Decision:** `RunningAccountTracker.backfillFromRunningProcesses` matches running apps against both `com.roblox.*` AND `com.626labs.RORORO.instance.*` prefixes.

**Rationale:** The tracker maps running Roblox PIDs to accounts so the cycler can drive auto-keys macros against the right window. The pre-fix filter was `bundleIdentifier.hasPrefix("com.roblox")`, which excluded our re-signed bundles entirely. Symptom: every Launch As after Round-1 of the fix showed "no macro assigned" because the tracker had no pids to associate with accounts.

**Consequences:** Tracker now sees re-signed bundles. The cycler's resolver waterfall (`account.activeMacroId` → `LaunchSettingsStore.defaultMacroBehavior` → `.none`) produces working pids for auto-keys playback.

## Decision 4 — `BundleIDRewriter` is a separate, tested helper

**Decision:** The bundle-ID rewrite + re-sign live in their own helper at `App/RORORO/Domain/BundleIDRewriter.swift`, called from `RobloxAppCopier.copyAppForInstance` at the end of the copy. Tested in `BundleIDRewriterTests.swift` against ad-hoc-signed fixture bundles (no Developer ID cert required for tests to pass).

**Rationale:** The plist edit + re-sign is a single atomic operation. Encapsulating it keeps `RobloxAppCopier` focused on copy mechanics and lets the rewrite logic be unit-tested in isolation. The test fixtures build minimal `.app` bundles in tempdir + ad-hoc-sign them, then verify the rewriter produces a bundle with the new CFBundleIdentifier and a fresh signature.

**Consequences:** Reusable — if future work needs to re-stamp other bundles for similar isolation reasons (e.g., per-account WebKit storage isolation when adding browser-embed features), the helper is the same.

## Alternatives considered

### A. HOME injection + direct binary spawn (plan v1, rejected after PoC)

The original plan: per-instance scratch `HOME` directory built by `RobloxInstanceHome`, direct binary spawn via `Process` running `Contents/MacOS/RobloxPlayer` with `task.environment = ["HOME": <scratch>, …]`. Cocoa apps resolve `~/Library/...` against `$HOME`, so bundle-ID-keyed writes would land per-instance.

**Why rejected:** Task 0 PoC at `tools/spawn-poc/` (since deleted) tested three URL-delivery mechanisms — argv, osascript, direct AppleEvent to pid — under the v1 architecture. All three failed. Diagnosis: direct binary spawn skips LaunchServices registration; Cocoa apps register `kAEGetURL` handlers as part of `NSApplication.run()` initialization, mediated by LS — direct-spawned processes are alive and rendering UI but invisible to AE dispatch. Without URL delivery, Roblox lands at the home/login screen instead of joining the requested game. The v1 architecture cannot deliver `roblox-player://1+launchmode:play+gameinfo:...` URLs.

Additional confound discovered: `cfprefsd` (the system preferences daemon) computes prefs paths from the requesting UID, not `$HOME`. NSUserDefaults writes would have bypassed the scratch home even if URL delivery had worked. The plist content is identity-free in practice (window position + Cocoa framework toggles), so this would have been cosmetic — but it would have failed silently as a design promise.

### B. App Sandbox containers (rejected — requires entitlements + cooperation from Roblox)

Per-instance App Sandbox containers (`~/Library/Containers/<bundleID>/Data/`) deliver path-level isolation via Apple's blessed mechanism. Requires the target app to opt into sandboxing via entitlement. Roblox is not sandboxed and we cannot make it so without re-signing with a sandbox entitlement, which is the failure mode of the prior re-sign attempt (commit `95d72fe`, see below). Container-style isolation also affects entitled API access (network, hardware) in ways that would likely break Roblox's runtime needs.

### C. `LSEnvironment` in Info.plist without bundle-ID rewrite (rejected — addresses only one storage class)

Adding `LSEnvironment = {HOME: <scratch>}` to the Info.plist would let LaunchServices propagate the env on launch (which `open -n -a` honors via LS but `posix_spawn` does not). Solves only filesystem-based writes; doesn't address `cfprefsd`-routed NSUserDefaults or system-managed paths. And: any Info.plist edit invalidates cdhash → requires re-sign → same distribution question as Decision 2.

### D. Bundle-ID rewrite WITHOUT re-sign (rejected — amfid refuses spawn)

Tested in commit `95d72fe`/`3e9b9ea` history (predecessor effort). Modifying Info.plist breaks cdhash; macOS amfid refuses to spawn the process under Hardened Runtime. Without re-sign, the bundle simply doesn't launch. Re-sign with `--sign -` `--deep` was the path; we use it.

### E. Cookie file management at rest (rejected — race-prone, doesn't survive session refresh)

Manage `~/Library/HTTPStorages/com.roblox.RobloxPlayer.binarycookies` directly: write account A's cookie before launching A, account B's cookie before launching B. Pattern used by some Windows alt-managers (`RobloxAccountManager`-style). Fails on macOS because Roblox's session-refresh tick re-reads the cookie file at runtime — whichever account's cookie was in the shared file at refresh time wins, regardless of which account is running. The bug recurs at every refresh interval; cookie-swap-at-launch only delays it.

### F. Multiple macOS user accounts (rejected — UX cliff)

Each Roblox instance launches under a different macOS user via `launchctl asuser <uid>` or AuthorizationServices. macOS gives each user their own `~/Library/`, so storage isolation is automatic and total. UX is brutal: separate desktops, no shared input, requires the user to maintain N macOS user accounts. Non-starter for the product.

### G. `sandbox-exec` with path-redirect profile (rejected — Apple-deprecated, fragile)

`sandbox-exec -f <profile.sb>` can intercept filesystem syscalls and redirect `~/Library/...` paths per-process. Could handle both filesystem AND `cfprefsd` reads/writes. Deprecated since macOS 14 Sonoma, still functional through Sequoia. Risk: Apple removes it in a future macOS with one beta cycle of warning. SBPL DSL is officially undocumented. Bad bet for a product shipping in 2026+.

## Bundle-ID-shared-storage Hard rule

Captured in `CLAUDE.md` so future contributors don't bypass `BundleIDRewriter` or reuse a bundle ID across instances:

> **Bundle-ID-keyed storage is shared across all running per-instance copies unless bundle IDs differ.** macOS keys cookies (`~/Library/HTTPStorages/<bundle>.binarycookies`), NSUserDefaults (`~/Library/Preferences/<bundle>.plist`), HTTPStorages, and WebKit storage by `CFBundleIdentifier`, not by bundle path. Multi-instance isolation requires each per-instance copy to have a unique bundle ID — `BundleIDRewriter` handles this at copy time + re-signs with our chosen identity (ad-hoc `--deep` by default) so amfid accepts the spawn. Don't add a launch path that bypasses `BundleIDRewriter`; don't reuse a bundle ID across instances.

## Verification

- **End-to-end smoke (2026-05-12 morning):** Two accounts side-by-side, both launched via the dev RORORO build, 20+ minute idle period, auto-rejoin fired on both. Real `com.roblox.RobloxPlayer.binarycookies` mtime stayed at `May 11 19:49:36 2026` baseline throughout the test. Each account's writes landed in `com.626labs.RORORO.instance.uid<slug>.binarycookies`. No identity swap observed. Macro cycler drove both windows correctly.
- **Task 4.5 PoC (2026-05-12 afternoon):** Confirmed `--force --deep --sign -` produces a launchable bundle. Roblox process alive (pid 68113) + crash handler attached, zero AMFI / library validation errors in system log.
- **Unit tests:** 363 tests pass, including `BundleIDRewriterTests` (3 tests covering stable derivation, codesign-reports-new-identifier verification, sanitization of unsafe chars) and `RobloxAppCopierTests` (14 tests including the real-Roblox integration that exercises the full copy + rewrite + re-sign path against `/Applications/Roblox.app`).

## Open items

- **Anti-cheat / Hyperion behavior under ad-hoc re-signed Roblox** — Nitrogen's population evidence (thousands of users, no widespread kick reports) is strong but not ours. A ~10-minute play smoke at v0.7.0 release-candidate stage is the prudent confirmation before tagging. Captured in `_followups-cookie-isolation.md` as the v0.7.0 release gate. Combined with ADR 0010's Launch-As smoke (`docs/_keychain-smoke-2026-05-12.md`).
- **Keychain password prompts on new-account launch** — RESOLVED by [ADR 0010](0010-keychain-prompt-elimination.md). The per-instance cdhash mismatch made every Launch As query Keychain through a re-signed bundle not in the original ACL → password prompt. ADR 0010 ships RORORO.keychain with the items Roblox queries pre-populated under a permissive ACL, so the query never falls through to login.keychain.
- **The four small UX cleanups** caught during morning smoke (footer "Cancel" label, right-click context-menu unification, picker inheriting-default hint, empty-state copy) are captured in `_followups-cookie-isolation.md` and intentionally deferred to v0.7.1 to keep this release focused on the cookie-isolation work.

## References

- Plan v2: `docs/superpowers/plans/2026-05-11-per-instance-cookie-isolation.md`
- Research synthesis: `docs/_research-2026-05-12-distribution.md`
- Followups + release gates: `docs/_followups-cookie-isolation.md` (untracked — to be reaped after v0.7.0 ships)
- Prior re-sign attempt: commits `95d72fe` (try) and `3e9b9ea` (revert) — the failure-mode breadcrumb that informed why re-sign is now viable with the corrected recipe.
- Sibling tools surveyed: `JadXV/Nitrogen`, `DollarNoob/Raptor-Manager`, `imeowforcash/celestial-ui`, `Insadem/multi-roblox-macos`, `AppleBlox/appleblox`.
