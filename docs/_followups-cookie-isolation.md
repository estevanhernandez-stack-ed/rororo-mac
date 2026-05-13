# Follow-ups from the cookie-isolation branch

> Captured 2026-05-12 after the morning smoke test validated the cookie isolation fix end-to-end (auto-rejoin scenario, 34 min, two accounts, real path mtime unchanged). These items did NOT block validation. None blocks shipping the branch *to local dev builds*. The Task 4.5 question gates shipping to the public DMG.
>
> **What this file is:** a staging area for non-blocking work. Triaged by priority. Untracked — delete after items either ship or migrate to a real tracker.

## Status legend

- 🚧 **OPEN** — to do
- ✅ **SHIPPED** — landed on this branch already
- 🔒 **GATING** — blocks shipping to a specific audience

---

## ✅ Shipped on this branch (reference)

- ✅ Picker visibility rule (commit `1261104`) — `sourcePicker` now shows whenever `!shareables.isEmpty || !owns.isEmpty`. Single-own-macro accounts no longer get a dead-end sheet. Closes the most load-bearing UX gap from morning smoke.

---

## 🔒 GATING — production-shipping question (still open)

### Task 4.5 — Does `--sign -` (ad-hoc) re-sign work on end-user machines?

The validated architecture re-signs per-instance copies with `Developer ID Application: Estevan Hernandez (82BSR56X5J)` — which only exists in your keychain. End users running the public DMG won't have that cert; the runtime re-sign would fail.

The plan's Task 4.5 (already documented in `docs/superpowers/plans/2026-05-11-per-instance-cookie-isolation.md`) is a 30-minute PoC: run the same re-sign recipe with `--sign -` instead of Developer ID, then verify Roblox launches and plays. Three outcomes:

- **Launches + plays clean:** ship as-is, runtime picks `-` for production builds. Done.
- **Launches but kicked at game-join:** Hyperion is stricter on ad-hoc-signed parents; investigate or accept "local dev only."
- **Doesn't launch at all:** entitlement is ignored under ad-hoc; the architecture is local-dev-only until a distribution-signing answer emerges.

🔒 **GATING** any merge that ships in the public DMG. Doesn't block local dev shipping or branch merge for personal use.

---

## 🚧 Real UX cleanups (small, ship-this-branch candidates)

### Footer "Cancel" → "Done" when nothing's pending

`AutoKeysRecorderV2Sheet.swift:322-339`. The Save button only renders during `phase == .stopped && actionCount > 0` (after a fresh recording). When the user opens the sheet just to bind a macro from the picker, the dropdown's `setActiveMacro` commits immediately — so "Cancel" is misleading; nothing's pending to cancel.

**Fix:** show `Done` (or `Close`) when there's nothing to discard, `Cancel` only when an in-progress recording could actually be thrown away. ~5-line conditional.

### Right-click context menu split → unified `Pick macro` submenu

`AutoKeysRowBadge.swift:59-90` has two separate top-level `Menu` items (`Use macro` for shareables, `Use my recording` for own). The sheet picker (`AutoKeysRecorderV2Sheet.swift:132-174`) already does the unified-with-sections shape. Bring the row badge in line:

```
Right-click badge →
  Record / re-record…
  ─────────
  Pick macro ▸
    ✓ No macro (cycler skips this account)
    ─────────
    My macros
      JUMP JUMP
    Shared from other accounts
      CelCPapa · OTHER MACRO
  Clear active macro       ← shown only when something's set
```

Per the [feedback_mac_right_click_is_supplemental memory](~/.claude/projects/-Users-estevanhernandez-projects-rororo-mac/memory/feedback_mac_right_click_is_supplemental.md) — right-click is for power users, but consistency between the visible-surface picker and the right-click escape hatch is still worth getting right. ~15-line refactor.

### Picker / home state conflation — "inheriting" hint

Home badge resolves the cycler's effective macro (with global-default fallback). Sheet picker shows the account's own setting (`activeMacroId`). When `activeMacroId` is nil but the global default IS a macro, the home shows `DEFAULT · MACRO_NAME` while the picker shows "No macro selected" — both accurate but confusing.

**Fix:** the picker's collapsed label should show `(inheriting global default: JUMP JUMP)` or similar when `activeMacroId == nil` AND `LaunchSettingsStore.defaultMacroBehavior` is `.useMacro(id)`. Keeps the picker honest about what's actually running. ~10 lines in `sourcePickerLabel`.

### Empty-state copy when the library has zero macros

After the visibility-rule fix, the picker still hides when *both* `owns.isEmpty` AND `shareables.isEmpty`. In that case, currently nothing renders — no message, no route to a fix. Should render an empty state with a path forward:

```
No macros in your library yet.
  • Record one for this account using the controls below.
  • Or share a macro from another account's row (right-click → toggle share).
```

~12 lines of SwiftUI.

---

## ✅ SHIPPED in v0.7.0 — eliminate the keychain re-prompt via RORORO.keychain + permissive ACL

> Landed via the keychain-prompt-elimination plan (`docs/superpowers/plans/2026-05-12-keychain-prompt-elimination.md`) + ADR 0010. RORORO.keychain installed first in user search list with pre-populated items. The Raptor-pattern hypothesis below turned out not to apply (Raptor's keychain is empty; their architecture is direct-spawn + binarycookies pre-write, not LaunchServices-mediated). What we shipped: `security add-generic-password -A` with empty placeholder values, since public Security framework does not expose code-requirement ACL embedding. See ADR 0010 for the trade-off.

## 🚧 v0.8 candidate (original stub, preserved for history) — eliminate the keychain re-prompt entirely via per-profile keychain (Raptor pattern)

**Source:** Research synthesis at `docs/_research-2026-05-12-distribution.md` + empirical investigation 2026-05-12 during v0.7.0 smoke. Validated peer pattern from `DollarNoob/Raptor-Manager` (Tauri/Rust, MIT-licensed).

**Problem this solves:** v0.7.0 ships with one keychain ceremony per account per machine (acceptable, ~one-time onboarding cost). What's NOT one-time: every time Roblox auto-updates `/Applications/Roblox.app`, the per-instance bundle copy's cdhash changes because the underlying binary content changed. The keychain ACL is keyed on cdhash (designated requirement: `cdhash H"…"`). So every Roblox update triggers one keychain re-prompt per account. Roblox releases roughly weekly. That's a recurring UX cost in perpetuity.

**The fix:** per-profile keychain. Instead of letting Roblox query the user's login keychain (where ACL grants are keyed on cdhash), give each per-instance bundle its OWN keychain that we control. Roblox's keychain queries land on our keychain, which doesn't have ACL grants tied to Roblox's binary. No cross-app ACL evaluation, no prompts ever.

**Implementation outline:**

1. **Per-account keychain creation** (on first launch of an account):
   ```
   security create-keychain -p "" ~/Library/Keychains/RORORO.{userId}.keychain
   security unlock-keychain -p "" ~/Library/Keychains/RORORO.{userId}.keychain
   ```
   The empty password is the trick — these keychains auto-unlock without user interaction. (Raptor uses this pattern.)

2. **Pre-populate the keychain with any entries Roblox needs.** This is the reverse-engineering step — we need to know what Roblox queries. Raptor-Manager presumably has this figured out; their `client.rs` is the reference. Start by inspecting what keychain items live under `com.roblox.RobloxPlayer` on a normal Roblox install (`security find-internet-password -s "roblox.com"` style probing).

3. **Inject the per-account keychain into Roblox's keychain search path at launch.** The mechanism: launch Roblox via a wrapper command that sets the keychain search path before exec'ing the binary. The `security` CLI can manipulate search paths, OR we can use the lower-level `SecKeychainSetSearchList` API. Raptor does this; their `launch_client` function is the canonical reference.

4. **Cleanup:** when an account is removed from RORORO, also remove its per-account keychain via `security delete-keychain`.

**Estimated:** half-day to full day of engineering. Reverse-engineering Roblox's keychain queries is the unknown-unknowns. Raptor-Manager's open source is the de-risking reference.

**Why this is v0.8 not v0.7.0:** changing the recipe AGAIN means one final keychain ceremony per account (transition cost). Better to ship v0.7.0 with the bounded one-time-per-recipe-change pattern, let users settle into it, then deliver the permanent fix in v0.8 with clear release-notes framing ("no more keychain prompts ever").

**Decision criteria for promoting to v0.7.x or holding for v0.8:**
- If post-v0.7.0 user feedback shows users hitting the post-Roblox-update prompt and finding it disruptive → promote to v0.7.1
- Otherwise: own branch, v0.8 work, clean focused effort

## 🚧 Stale per-instance bundle pile-up in `~/Applications/RORORO/instances/`

**Observed during v0.7.0 smoke (2026-05-12):** the `instances/` dir accumulates copies from every recipe iteration during development + every per-launch UUID from pre-stable-bundle-ID builds. Currently 9+ stale `com.roblox.RobloxPlayer` bundles (from before cookie isolation shipped) + several old UUID-keyed copies.

**Current cleanup:** `RobloxAppCopier.cleanupStaleInstances(olderThan: 86_400)` runs at boot, removes parent dirs older than 24h. Works fine for routine accumulation but doesn't help during active development when many recipe variations land in the same day.

**Worth considering:**
- Shorten the cleanup window to 1h for non-current copies on first launch of each session
- Add a "manage instances" panel that surfaces total disk space + a "clean up older than X" button
- Or just rely on the 24h walker — these copies are ~600MB each, but disk space is cheap in 2026

**Estimated:** ~1 hour for any of these. Low urgency; current 24h walker handles steady-state.

## 🚧 Feature requests (bigger, follow-up branches)

### "Record (library only)" option in the picker

New entry at the top of the picker (alongside "No macro") — opens the recorder UI but saves the captured stream to MacroStore as a library-owned macro **without** binding it to the current account's `activeMacroId`. Users could record once + assign from multiple accounts after.

State model: `Macro.ownerUserId` would be `nil` for library-only macros (or set to a synthetic "library" pseudo-id). Sharing semantics: always shared (no owner = no hide-from-others affordance). UI: a new entry point in the dropdown + a small banner during recording explaining "this will save to your library, not bind to {{account}}."

**Estimated:** ~half-day of work. Touches: AutoKeysRecorderV2Sheet, MacroStore CRUD, the resolver waterfall (no change needed if library-only macros behave like normal shared ones).

### Click-to-target window for the library-record flow

The per-account recorder flow targets `runningTracker.pid(for: account.userId)` — bound to the row you opened the sheet from. That's correct for the per-account flow.

The library-record flow has **no row context** — there's no account to bind to. Natural UX: arm the recorder, then the first Roblox window the user clicks becomes the target. The frontmost-tracking infrastructure already exists (`NSWorkspaceFrontmostAppProvider`); the recorder's state machine could enter `.armed_waiting_for_target` and transition to `.recording_active` on the next workspace-activation notification matching a Roblox bundle.

**Estimated:** ~2 hours on top of the library-record feature. Naturally pairs with that work.

---

## 🚧 Cleanup tasks (low priority)

### Stale per-instance cookie jars from pre-fix builds

Four `~/Library/HTTPStorages/com.626labs.RORORO.instance.<random-uuid>*` directories + their `.binarycookies` files left over from yesterday afternoon's PoC and last night's broken UUID-keyed dev builds. Won't be touched by the new build (different bundle IDs). Safe to delete:

```bash
rm -rf ~/Library/HTTPStorages/com.626labs.RORORO.instance.{0cd49eb1,42128fa2,e8654dc7,c6196c3a}*
```

**Optional ship-with-the-branch:** add a one-time cleanup migration on first launch that walks `~/Library/HTTPStorages/com.626labs.RORORO.instance.*` and deletes UUID-shaped suffixes (length-36 hex-with-dashes). Skip uid-prefixed ones. ~20 lines. Avoids dust accumulation in users' Library folders during the fix's rollout. Probably overkill for the size; user choice.

### Two accounts sharing display name "CelCPapa"

Roblox allows multiple accounts with the same display name. The home badge attribution (`"\(owner.uppercased()) · \(macro.name.uppercased())"`) becomes ambiguous when two accounts share a display name — both show as `CELCPAPA` and the user can't tell which account owns which macro.

**Fix:** when an owner-attribution would collide with another account in the store, include the `@username` to disambiguate. ~5 lines in `AutoKeysRowBadge.swift:130-150` and the same pattern in `pickerLabel(for:)` callers.

Not caused by anything on this branch; surfaced because the user is now paying close attention to ownership.

---

## How I'd order this

If the goal is "ship the cookie-isolation branch":

1. 🔒 **Task 4.5** — must answer this before public-DMG merge. 30 min.
2. ✅ Picker visibility rule (already shipped, `1261104`).
3. 🚧 Footer label fix + right-click unification + inheriting hint + empty-state copy — small UX cluster that ships well together as a single `polish/macro-picker-consistency` commit, ~hour total. Could land on this branch or a follow-up. **My read:** follow-up branch to keep this one focused on cookie isolation.
4. 🚧 Library-record + click-to-target — own branch later. Feature work, not polish.
5. 🚧 Cleanup tasks — own time, no urgency.

If the goal is "polish what's visible to you right now while you remember":

Reverse the order: do the small UX cluster (#3) now while context is fresh, then Task 4.5, then the rest. Lower context-switching cost.
