# Morning handoff — v0.7.0 keychain prompt elimination

> Captured 2026-05-12 ~23:15 after a long smoke session. v0.7.0 is **not yet shippable.** Architecture is partially proven; one failure mode is still open. This file is the handoff for the next agent to pick up cold.

## Paste-this-as-the-opener prompt

```
Resume v0.7.0 keychain prompt elimination on branch fix/launcher-cookie-isolation. Architecture from ADR 0010 (RORORO.keychain prepended to user's search list, pre-populated with the items Roblox queries) is partially proven but has one failure mode still open: even with our RORORO.keychain entry in place, accounts whose per-instance bundle cdhash isn't already in login.keychain's ACL still trigger the SharedROBLOSECURITYForStudio prompt at game-launch time. Read docs/_handoff-2026-05-13-keychain.md, docs/decisions/0010-keychain-prompt-elimination.md, and docs/_keychain-smoke-2026-05-12.md to load context. Two specific investigations are queued (see handoff doc): (1) capture Roblox's actual keychain query via log stream to determine if it uses kSecUseKeychain to bypass search list; (2) try alt attribute shape SecItemAdd with kSecAttrService unset, matching login.keychain's actual item shape. Do those first before any more code changes. v0.7.0 ship gate is still open — do NOT tag.
```

## State of the branch

- Branch: `fix/launcher-cookie-isolation` — 7 commits on top of ADR 0009 (per-instance cookie isolation).
- Version bumped to 0.7.0 (commit `51c4e21`).
- 13 keychain unit tests green at HEAD. Full suite: 378 tests, 0 failures.
- **Uncommitted changes:** `App/RORORO/Domain/RororoKeychain.swift` has the `productionPath → .keychain-db` fix + bundled `set-keychain-settings` + `unlock` in `create()`. Don't lose this — it's load-bearing.

## What is empirically proven to work

1. **Bootstrap installs RORORO.keychain correctly** (with my uncommitted productionPath fix). Marker persists to UserDefaults. Re-launches do not re-create the file.
2. **Non-empty placeholder values survive a game launch.** Empty values get deleted by Roblox during the game-launch flow (validated 2026-05-12, see "What's broken" below).
3. **A brand-new account** (no prior Roblox login on this machine, no cdhash in any ACL) launches end-to-end with ONLY the mic TCC prompt fired. Zero keychain prompts.
4. **An account whose cdhash was previously added to login.keychain's ACL via Always-Allow** launches end-to-end with zero prompts. (This is the "cached" case — login.keychain's ACL already accepts the cdhash.)

## What's still broken

**Accounts whose per-instance bundle cdhash is NOT already in login.keychain's ACL** still trigger a SharedROBLOSECURITYForStudio prompt at game-launch time, even with our RORORO.keychain entry in place. This is the central unresolved issue. Two possible explanations, both testable:

- **Hypothesis A:** attribute-shape mismatch. Our entry uses `service = URL` (security CLI requires `-s`, can't write `service = NULL`). Roblox's login.keychain entry has `service = NULL`. If Roblox's query filters by `service = NULL` (or omits the service attribute), our entry doesn't match → search falls through to login.keychain → ACL fails → prompt.
- **Hypothesis B:** Roblox bypasses the search list. The `SecItemCopyMatching` API accepts a `kSecUseKeychain` parameter that forces a specific keychain. If Roblox passes `login.keychain`, our RORORO.keychain entry is never consulted, regardless of search-list order.

## Two diagnostics to run first (morning, before any code changes)

### Diagnostic 1 — capture Roblox's actual keychain query

```bash
# Start log stream BEFORE the launch
log stream --predicate 'subsystem == "com.apple.securityd"' --info --debug > /tmp/securityd-launch.log &
LOG_PID=$!

# Launch a Launch As that triggers the prompt (an account whose cdhash isn't cached)
# (do this in RORORO)

# Stop after the prompt fires
sleep 30 && kill $LOG_PID
grep -i 'SharedROBLOSECURITY\|RobloxPlayer\|com.626labs\|SecItemCopyMatching' /tmp/securityd-launch.log | head -50
```

Look for:
- `kSecUseKeychain` reference → Hypothesis B confirmed
- Specific keychain path in the query → confirms whether search list is consulted
- `kSecAttrService` value in the query → identifies the exact attribute shape Roblox uses

### Diagnostic 2 — try alt attribute shape via direct SecItemAdd

The `security` CLI requires `-s` so it can't produce `service = NULL` items. Write a small Swift script that calls `SecItemAdd` directly:

```swift
import Security
import Foundation

let kcPath = "/Users/estevanhernandez/Library/Keychains/RORORO.keychain-db"
var kc: SecKeychain?
SecKeychainOpen(kcPath, &kc)

let attrs: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrAccount as String: "https://www.roblox.com/:SharedROBLOSECURITYForStudio",
    // INTENTIONALLY no kSecAttrService — match login.keychain's shape exactly
    kSecValueData as String: "placeholder".data(using: .utf8)!,
    kSecUseKeychain as String: kc!,
]
let status = SecItemAdd(attrs as CFDictionary, nil)
print("status: \(status)")
```

If that lands with `service = NULL` matching, retry the failing-account launch. If prompts stop → Hypothesis A confirmed → patch `RororoKeychainItems.swift` to use direct `SecItemAdd` (drop the CLI), make the service attribute optional in `RoroKeychainItem`, and reset the smoke.

## Known bugs in code (queued, don't ship without)

1. **`RororoKeychainItems.add` uses `-w ""` empty placeholder.** Roblox wipes the item during game-launch flow. Fix: use a non-empty placeholder string (e.g. `"rororo-placeholder-do-not-trust"`). **Validated by manual smoke 2026-05-12.**
2. **`RororoKeychainBootstrap.ensureIfNeeded` doesn't `synchronize()` after `defaults.set(...)`.** If the app crashes/quits before NSUserDefaults's lazy flush, the marker is lost → bootstrap re-runs full sequence next launch. Probably benign with the productionPath fix (re-runs are now idempotent), but harden anyway.
3. **`RororoKeychain.create` was missing `set-keychain-settings` + immediate `unlock` after create.** FIXED in uncommitted edit. Land before tagging.
4. **`RororoKeychain.productionPath` was `.keychain` (no -db).** macOS auto-appends `-db`, but `FileManager.fileExists` against `.keychain` returns false → bootstrap re-creates → fails with `errSecDuplicateKeychain` (status 48). FIXED in uncommitted edit.
5. **Defensive `ensureUnlocked()` helper for launch-time unlock** was proposed but rejected by user. Decide if needed after Diagnostic 1 results. If Hypothesis B is true, this won't help. If Hypothesis A is true and we fix the shape, this is belt-and-suspenders.

## Current state of the user's machine (don't blow it away without resetting first)

- `~/Library/Keychains/RORORO.keychain-db` exists, has `SharedROBLOSECURITYForStudio` item with value `rororo-placeholder-do-not-trust` (manually added 2026-05-12 ~23:00; production code still uses empty value).
- Search list: RORORO.keychain first, then login, system, system-root.
- Keychain settings: `no-timeout` (manually set; code doesn't set this yet — see uncommitted fix).
- `defaults read com.626labs.rororo-mac RororoKeychainBootstrapVersion` returns `1`.
- login.keychain's `SharedROBLOSECURITYForStudio` item has accumulated multiple per-instance cdhashes in its ACL from repeated Always-Allow clicks. Polluted but not destructive.
- RORORO process state: may have a running instance from the last test. Verify with `ps -ef | grep '[R]ORORO.app'` before relaunching.

## Reset to clean state (if needed)

```bash
pkill -9 -x RORORO 2>/dev/null
defaults delete com.626labs.rororo-mac RororoKeychainBootstrapVersion 2>/dev/null
security delete-keychain ~/Library/Keychains/RORORO.keychain-db 2>/dev/null
# Then rebuild + relaunch via /usr/bin/open -n /path/to/RORORO.app
```

If the search list still has stale test-keychain entries from prior tearDown failures, restore explicitly:
```bash
security list-keychains -d user -s \
  "/Users/estevanhernandez/Library/Keychains/login.keychain-db" \
  "/Library/Keychains/System.keychain" \
  "/System/Library/Keychains/SystemRootCertificates.keychain"
```

## Files to load first when picking up

1. `docs/_handoff-2026-05-13-keychain.md` (this file)
2. `docs/decisions/0010-keychain-prompt-elimination.md` (architecture + design rationale)
3. `docs/decisions/0009-per-instance-cookie-isolation.md` (the per-instance bundle ID work this builds on)
4. `docs/_keychain-smoke-2026-05-12.md` (smoke procedure + observations)
5. `docs/_keychain-probe-2026-05-12.md` (what's in login.keychain pre-fix)
6. `App/RORORO/Domain/RororoKeychain*.swift` (the four keychain files)
7. `App/RORORO/UI/KeychainBootstrapPromptSheet.swift` (onboarding UX)

## Decision needed from the user before shipping

If both diagnostics fail to eliminate the prompt — i.e., the architecture fundamentally cannot block the prompt for some Roblox query paths — decide between:

- **Option A — ship v0.7.0 anyway with the partial fix.** Bug eliminated for ~80% of accounts; users see fewer prompts but not zero. Document the residual case in release notes.
- **Option B — hold v0.7.0; promote the per-cdhash trusted-app list from ADR 0010 Decision 3 (the deferred hardening path) to the current release.** Adds per-release build step (cdhash list maintained at build time). Tighter security posture but more build complexity.
- **Option C — pivot to a different mechanism entirely.** E.g., delete login.keychain's `SharedROBLOSECURITYForStudio` item on first run (requires user authorization, one prompt — same as our current ceremony) so Roblox is forced to write a fresh entry that lands in RORORO.keychain (because search list order). Untested. Could work if Roblox's "no existing item" path creates with `-A`-style permissive ACL, or could just re-introduce a cdhash-locked ACL.

Default: **don't tag v0.7.0** until one of these resolves clean end-to-end.
