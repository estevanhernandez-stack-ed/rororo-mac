# ADR 0010 — Keychain prompt elimination via RORORO.keychain + permissive ACL

**Date:** 2026-05-12
**Status:** Accepted (shipped on `fix/launcher-cookie-isolation`, commits `cb7f2bc` → `813da2b`)
**Slope:** Keychain prompt elimination — closes the v0.7.0 ship gate
**Pairs with:** ADR 0009 (per-instance cookie isolation). ADR 0010 fixes the password-prompt UX cost ADR 0009 introduced.

## Background

ADR 0009 (commits `a395c62` → `c447ece`) shipped per-instance bundle ID re-sign — each `Launch As` mints a fresh `com.626labs.RORORO.instance.uid<slug>` bundle and re-signs it ad-hoc `--deep`. That fixed multi-instance session-identity collisions (the long-latent "logged me out of both" / "Error 264" / "teleport fails — same account" cluster).

It introduced a UX cost: **every per-instance bundle has a fresh cdhash**, and Roblox queries `~/Library/Keychains/login.keychain-db` on launch for items including the URL-shaped GenericPassword entry `https://www.roblox.com/:SharedROBLOSECURITYForStudio`. That entry's ACL is keyed on the cdhash of the original `/Applications/Roblox.app`. Each per-instance Launch As → cdhash not in ACL → macOS password prompt. Two accounts → two prompts. Onboarding-grade UX cost, persisting across every Roblox auto-update that rewrites cdhash on the original install.

Roblox falls back to URL-ticket auth (the path RORORO uses), so login succeeds regardless of whether the user enters their password — the prompt is nuisance, not a blocker. But it makes the product feel broken.

## Decision 1 — Ship a private RORORO.keychain, prepended to the user's search list

**Decision:** At first run on every machine, RORORO creates `~/Library/Keychains/RORORO.keychain` (empty password → auto-unlocking), prepends it to the user's keychain search list, and pre-populates it with the items Roblox queries on launch.

```
~/Library/Keychains/RORORO.keychain  (first in search list)
~/Library/Keychains/login.keychain-db
/Library/Keychains/System.keychain
/System/Library/Keychains/SystemRootCertificates.keychain
```

**Rationale:** macOS `SecItem*` queries search keychains in `list-keychains` order. With RORORO.keychain first and the queried item present, Roblox finds the item in our keychain, the search never falls through to login.keychain, and login.keychain's cdhash-locked ACL is never evaluated. No prompt.

**Pre-population is empty placeholder values, not real session credentials.** Real `.ROBLOSECURITY` cookies live in `~/Library/HTTPStorages/com.626labs.RORORO.instance.uid<slug>.binarycookies` per ADR 0009. The keychain items Roblox queries on launch are auxiliary; their values are not load-bearing for session auth, only their existence. Roblox's launch-time behavior in the absence of the queried item is to create the item, not error — but the prompt fires on READ when the item exists in a different keychain with restrictive ACL. Pre-populating with empty UTF-8 means the read succeeds in RORORO.keychain, no prompt.

**Consequences:**

- New domain: `App/RORORO/Domain/RororoKeychain.swift` (CLI primitives), `RororoKeychainItems.swift` (item add with ACL), `RororoKeychainBootstrap.swift` (orchestrator), `RoblxKeychainProbeList.swift` (static list of items to pre-populate).
- New UI: `App/RORORO/UI/KeychainBootstrapPromptSheet.swift` — one-time onboarding sheet explaining the one macOS password prompt the user is about to see.
- Wired into `App.swift .onAppear` (presents sheet when `needsOnboarding`) and `MultiInstanceCoordinator.bootIfNeeded` (defensive `ensureIfNeeded` for URL-handoff edge case).
- 13 unit tests cover the keychain primitives, item population, and bootstrap orchestration. Probe-list pin test guards against accidental list deletion.
- One-time macOS password prompt at first run (`security list-keychains -s` REQUIRES authorization). Unavoidable system rule, framed by the onboarding sheet. Zero prompts thereafter, including on new accounts.
- Stable across Roblox auto-updates: the original Roblox.app's cdhash can change with every weekly Roblox update without affecting our prompt-elimination — RORORO.keychain is consulted first, login.keychain's ACL never evaluated.

## Decision 2 — Use `security add-{generic,internet}-password -A` for ACL, NOT a code-signing-requirement ACL

**Original plan (`docs/superpowers/plans/2026-05-12-keychain-prompt-elimination.md`):** build a wildcard-prefix code-signing-requirement ACL via `csreq`-compiled `identifier like "com.626labs.RORORO.instance.*"`, attached to each item via `SecAccess + SecACL + SecTrustedApplicationCreateFromRequirement`. Every re-signed bundle would satisfy the ACL by virtue of its bundle identifier; no per-cdhash ceremony.

**Reality check during implementation:** macOS's public Security framework does NOT expose an API to embed a code-signing requirement directly into a Keychain ACL's subject:

- `SecAccessCreate` accepts an `applicationList: CFArray?` (or NULL). The array elements are `SecTrustedApplicationRef`s constructed via the deprecated `SecTrustedApplicationCreateFromPath` (path-based, not requirement-based).
- `SecTrustedApplicationCreateFromRequirement` is **not in the public Security framework headers**. References exist in legacy CSSM internals, deprecated since macOS 10.7 with no maintained replacement.
- `SecACLSetSimpleContents` accepts the same path-based application list. There is no API surface for "ACL accepts any code matching this requirement."
- The macOS Sierra-era "partition list" mechanism (`security set-generic-password-partition-list`) accepts `teamid:<TEAMID>` and `apple:` entries but NOT wildcard identifier prefixes.

**Decision:** use `/usr/bin/security add-{generic,internet}-password -A`. The `-A` flag creates the item with an ACL that allows any application to read/modify without prompting. This is the production-tested workable path; Raptor-Manager and Nitrogen both use it (verified via source read 2026-05-12).

**The security trade-off is identical to the originally planned wildcard-prefix design:**

- Plan A (wildcard prefix): any ad-hoc-signed binary with `com.626labs.RORORO.instance.*` identifier reads the items.
- Plan B (what we ship, `-A`): any application reads the items.

Both are weaker than the user's login keychain's normal cdhash-locked ACL. **Mitigation: the items hold empty placeholder values, not real credentials.** A rogue local app reading `SharedROBLOSECURITYForStudio` from RORORO.keychain gets back an empty string. The actual session cookie continues to live in `~/Library/HTTPStorages/com.626labs.RORORO.instance.uid<slug>.binarycookies` (per-instance, ADR 0009).

If Roblox ever writes a real value to one of these items at runtime, the threat surface widens to "any local app could read whatever Roblox stored there." Mitigation: that value would be the Studio-variant shared cookie, not the Player session cookie. Real Player auth continues to flow through the URL-ticket path (RORORO's normal launch) and the per-instance HTTPStorages cookie jar, neither of which routes through Keychain.

A rogue local app on macOS already has near-total access to the user's home directory without sandboxing. The marginal attack surface added by this ACL is small relative to existing macOS posture for non-sandboxed apps.

**Consequences:**

- The plan's `RoroKeychainItem` model + `RororoKeychainItems.add` implementation diverges from the plan's framework-level approach. Plan author update: replace the `SecAccess` + `csreq` machinery with the `security` CLI invocation in code. Documented in `RororoKeychainItems.swift` header.
- The CLAUDE.md "Hard rules" addition lands as written below — the rule is the same (don't bypass the bootstrap; don't tighten the ACL without a logged decision) even though the technical mechanism is different.

## Decision 3 — Hardening path for v0.8+ (deferred)

**Future direction (not v0.7.0):** maintain a static list of cdhashes of every published `com.626labs.RORORO.instance.*` build at build time, encoded into a partition list via `security set-generic-password-partition-list`. Each release would update the list with the cdhash of that release's RORORO.app binary. Per-instance copies inherit the parent's signature when ad-hoc-signed via `--deep`, so their cdhash is derived from RORORO.app's parent binary — predictable at build time.

**Why deferred:** adds a per-release build step (compute parent cdhash, embed in partition list call) without changing the user-visible outcome at v0.7.0 (which is "zero prompts after the one-time onboarding"). The trade-off becomes worth-it only if (a) we learn that Roblox writes real credentials into these keychain items in a future release, or (b) external review of the security posture surfaces concerns about the broad ACL.

## Decision 5 — Re-plant the probe items on every Launch As, not just at bootstrap

**Background:** the original Decision 1 design assumed one-shot population at bootstrap was sufficient — items would live in RORORO.keychain forever, Roblox would read them on each launch, no further write needed. Live smoke on 2026-05-13 invalidated that assumption.

**Discovery via `log stream` capture:** during each Roblox game-launch flow, `RobloxPlayer` opens RORORO.keychain for write and commits **two atomic writes** that net to deleting our pre-populated `SharedROBLOSECURITYForStudio` item:

```
10:05:11.077 RobloxPlayer: atomicfile created RORORO.keychain-db.sb-...-Msb2Ll
10:05:11.082 RobloxPlayer: committed Msb2Ll to RORORO.keychain-db
10:05:11.084 RobloxPlayer: committing (second pass)
10:05:11.085 RobloxPlayer: committed QSUgzp to RORORO.keychain-db
```

File size drops 22548 → 20460 bytes — exactly one item removed. `find-generic-password` returns `errSecItemNotFound` after the launch. Roblox presumably reads our placeholder value, decodes it as an invalid cookie, and wipes the entry. The `-A` ACL (allow any app) lets RobloxPlayer perform the delete.

**Failure mode without replant:** first Launch As after bootstrap succeeds (item present → search list wins → no prompt). Roblox then wipes. Every subsequent Launch As whose per-instance cdhash isn't already in login.keychain's ACL falls through to login.keychain → cdhash-locked ACL eval → password prompt. Validated on 2026-05-13 morning smoke: 2 prompts fired across ~5 launches after the first.

**Decision:** in `MultiInstanceCoordinator.performLaunch`, immediately before `openRoblox(at: copy, with: url)`, replant every item in `RoblxKeychainProbeList.items` via `RororoKeychainItems.add`. The call is sync, runs on the launch worker queue (no main-thread block), and is idempotent (find-then-add; tolerates `errSecDuplicateItem`).

```swift
RororoKeychainBootstrap.ensureUnlocked()
for item in RoblxKeychainProbeList.items {
    try? RororoKeychainItems.add(item, toKeychainAt: RororoKeychain.productionPath)
}
try await openRoblox(at: copy, with: url)
```

**Rationale:** the replant is cheap (one find + one add per item, both `/usr/bin/security` shell-outs, <100ms total). It runs sequentially with `openRoblox`, so there is no race: our item lands before Roblox starts reading the keychain. Idempotent: when the item is already present (rare path — only on a launch immediately after another that we didn't see Roblox's wipe of yet), the add is a no-op.

**Verification (2026-05-13 morning smoke):** with the patch in place, 5+ stress-test Launch As calls across multiple per-instance cdhashes, all of which prompted in the prior smoke. Result: **0 prompts, 0 `ObjectAcl REJECTS`** in the securityd log capture. 8 RobloxPlayer commits to RORORO.keychain during the smoke (still deletes our items each launch) — but our replant beats Roblox to the next query every time.

**Consequences:**

- New `MultiInstanceCoordinator.swift` delta: per-launch replant block (10 lines including header comment). No new files, no new tests required — the replant uses already-tested `RororoKeychainItems.add` + `RororoKeychain.unlock`.
- The bootstrap version-bump growth mechanism (Decision 4) still matters for adding new entries to `RoblxKeychainProbeList`, but the day-to-day "items must be present at launch" guarantee comes from the per-launch replant, not the bootstrap.
- Bootstrap is now "set up the keychain + search list + plant initial items so the very first launch wins" rather than "plant items once forever." The semantic distinction is small but worth naming.

**CLAUDE.md hard rule update:** the existing rule ("don't bypass `RororoKeychainBootstrap.ensureIfNeeded`") still holds. The new implicit rule: **don't add a launch path that bypasses the `MultiInstanceCoordinator.performLaunch` replant block** — without it, the second Launch As on any uncached cdhash prompts. Documented in the surrounding comment block in the source.

## Decision 4 — `RoblxKeychainProbeList` is a static array, growth via version bump

**Decision:** The items pre-populated into RORORO.keychain are encoded as a static `[RoroKeychainItem]` array in `RoblxKeychainProbeList.swift`. Adding entries requires (a) editing the array and (b) bumping `RororoKeychainBootstrap.currentVersion`.

The `currentVersion` bump triggers `RororoKeychainBootstrap.ensureIfNeeded` to re-run the populate pass on next launch. Each `RororoKeychainItems.add` is idempotent (calls `find-generic-password` first; treats `errSecDuplicateItem` as success), so the re-population pass is safe to run even with no new items.

**Rationale:** the keychain item Roblox queries is determined by RUNTIME behavior of Roblox.app, which is closed-source and which we cannot enumerate at build time without observing live. The probe approach (observe what gets queried via dump-keychain, append to the list, version-bump, ship) is the simplest mechanism that scales to "as new items surface, we add them." See `docs/_keychain-probe-2026-05-12.md` for the re-probe procedure.

**At v0.7.0 ship:** one item observed on the dev machine — `SharedROBLOSECURITYForStudio` (GenericPassword class; service and account both = the full URL string). No Player-variant or Studio-extension items observed. Future observations append to the list.

## Alternatives considered

### A. Per-account keychains (Raptor-Manager pattern)

Raptor uses one keychain per profile (`RORORO.{userId}.keychain`), each unlocked at launch. Required a search-list-add per account, which is a per-account macOS password ceremony — repeated for every new account, defeating the user-visible goal.

Also: **Raptor's keychains are empty.** Their architecture is HOME-rebase + binarycookies pre-write for direct-spawn launches; the keychain is unused by Roblox at runtime under that architecture. We use LaunchServices-mediated `open -n -a <copy.app> <roblox-player-URL>` because `kAEGetURL` URL delivery requires LS launch (proven by Task 0 PoC predating ADR 0009). Their pattern does not transfer.

### B. Delete the conflicting login.keychain entries

Could remove `SharedROBLOSECURITYForStudio` from login.keychain on first run, eliminating the conflict at its source. Two problems:
1. Requires `security delete-internet-password` against login.keychain — same authorization prompt as search-list-add, no UX win.
2. Roblox would recreate the item on next launch (creating items doesn't trigger ACL prompts — only reading existing items with restrictive ACL does). The item would land back in login.keychain with the same cdhash-locked ACL, restoring the failure mode after one launch.

### C. Per-cdhash trusted-app list (the v0.8+ hardening path)

Would deliver tighter security but requires per-release ceremony. See Decision 3.

### D. Container-based isolation via App Sandbox

Sandboxing each per-instance copy would isolate keychain access via App Sandbox containers. Roblox is not sandboxed and we cannot make it so without re-signing with a sandbox entitlement, which has its own failure modes (sandbox-violation kicks at runtime, App-Sandbox-routed entitled-API access breaks Roblox features). Out of scope.

### E. Suppress prompts via `security set-key-partition-list` on the original login.keychain item

Theoretically possible — modify the existing item's partition list to include `teamid:82BSR56X5J` so our ad-hoc-signed copies satisfy it. But:
1. Ad-hoc signatures have no team identity. The partition list `teamid:` entry would not match.
2. The `apple:` entry could permit Apple-signed binaries; ad-hoc-signed isn't Apple-signed.
3. Modifying the login.keychain item requires user authorization — same prompt as our search-list-add.

No win.

## CLAUDE.md hard rule (lands with this ADR)

> **Don't add a launch path that bypasses `RororoKeychainBootstrap.ensureIfNeeded`.** New launch entry points must wait for the bootstrap to complete (or run it themselves) before invoking `RobloxAppCopier`. Otherwise Roblox queries Keychain via a re-signed bundle whose `SecItem*` query falls through to login.keychain → cdhash mismatch → password prompt.
>
> **Don't tighten the ACL** (`security ... -A` allow-any-app) to a per-cdhash list without a logged decision. The current ACL is what makes new accounts work without ceremony; a per-cdhash variant breaks every new Launch As unless paired with a per-release build step (see ADR 0010 Decision 3).

## Verification

- **Unit tests:** 13 new tests, all green at commit `b085d94`:
  - `RoblxKeychainProbeListTests` × 2 (list-not-empty, includes-SharedROBLOSECURITYForStudio)
  - `RororoKeychainTests` × 4 (create, unlock, prependToSearchListPutsKeychainFirst, prependIsIdempotent)
  - `RororoKeychainItemsTests` × 3 (addGenericPassword, addInternetPassword, addIsIdempotent)
  - `RororoKeychainBootstrapTests` × 4 (ensureCreatesAndPopulates, secondEnsureIsNoOp, versionResetTriggersRePopulate, needsOnboardingReflectsMarker)
- **Implicit smoke (during test runs):** RORORO.keychain installed at `~/Library/Keychains/RORORO.keychain-db`, marker = 1 in `com.626labs.rororo-mac` defaults, probe item populated, search list correctly orders RORORO.keychain first.
- **Live Launch-As smoke:** pending user run — see `docs/_keychain-smoke-2026-05-12.md` for the procedure. Three accounts launched in succession, expected zero prompts on accounts 2+3. Combined with the 10-minute play smoke to also close ADR 0009's Hyperion / anti-cheat open item.

## Open items

- ~~**Live smoke completion**~~ — **RESOLVED 2026-05-13.** Smoke captured 0 prompts across 5+ Launch As stress test on the patched build. See Decision 5 for the per-launch replant fix that closed the gate.
- **Per-cdhash hardening (v0.8+):** Decision 3. Promote to v0.7.x if external review surfaces ACL concerns; otherwise own branch, own slope.

## References

- Plan: `docs/superpowers/plans/2026-05-12-keychain-prompt-elimination.md`
- Probe results: `docs/_keychain-probe-2026-05-12.md`
- Smoke procedure: `docs/_keychain-smoke-2026-05-12.md`
- Followups + release gates: `docs/_followups-cookie-isolation.md` (the v0.8 keychain stub gets struck — landed in v0.7.0)
- Sibling tools surveyed (Raptor, Nitrogen, celestial-ui): `docs/_research-2026-05-12-distribution.md`
- ADR 0009 (per-instance cookie isolation): `docs/decisions/0009-per-instance-cookie-isolation.md`
