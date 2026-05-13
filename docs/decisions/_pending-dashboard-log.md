# Pending 626Labs Dashboard decision-log entries

> **What this file is:** A staging area for decision-log entries that should land in the 626Labs Dashboard via `mcp__626Labs__manage_decisions log`, but couldn't be logged at write time because the MCP wasn't wired up on the writing machine.
>
> **What to do with it:** Once the 626Labs MCP is online on the machine you're working from, paste each entry below into a `manage_decisions log` call (one call per `---` separator), then `git rm` this file in the same commit that lands ADR 0009.
>
> **Why local-file staging:** Keeps the decision content in the audit trail (git history) even if the dashboard write is delayed by hours or days. Dashboards can be backfilled; vanished context can't.

---

## Entry 1 — Pivot from HOME-injection to re-sign + unique bundle ID for cookie isolation

**Type:** Architectural choice + Overcame a momentous hurdle
**Project:** rororo-mac (bind via repo URL `github.com/estevanhernandez-stack-ed/rororo-mac` — if no match, log unbound with `projectId: null` and tag in description)
**Branch:** `fix/launcher-cookie-isolation`
**Date:** 2026-05-11
**Status:** Architecture validated; production code in progress

### Summary

The multi-instance Roblox cookie-collision bug (one account "logs in as" another after a session refresh) traces to macOS keying cookies / NSUserDefaults / HTTPStorages / WebKit storage by `CFBundleIdentifier`, not bundle path. Two architectural approaches were considered, with a planned approach that turned out to be impossible and a rejected approach that turned out to be correct:

**v1 (rejected after PoC):** Per-instance `$HOME` redirect via direct binary spawn (`Process` running `Contents/MacOS/RobloxPlayer`) with `task.environment = ["HOME": <scratch>, …]`. PoC (Task 0 of the original plan) discovered three independent failure modes:

- `argv[1]` URL delivery: Roblox doesn't read URLs from argv.
- `osascript` URL delivery: bundle-ID resolution incompatible with multi-instance (same-ID copies confuse the AppleScript runtime → `-609 connectionInvalid`).
- Direct `kAEGetURL` to spawned pid: `-600 procNotFound` — direct-binary-spawned processes are alive and rendering UI but aren't registered with LaunchServices, so the AppleEvent dispatcher can't find them as eligible targets.

Diagnosis: direct binary spawn skips LaunchServices registration; without that registration, the spawned Cocoa app's `kAEGetURL` handler never gets installed. **All three URL-delivery candidates rely on AppleEvents in some form.** The v1 architecture cannot work on macOS without a complete redesign.

**v2 (validated end-to-end):** Per-instance unique `CFBundleIdentifier` (`com.626labs.RORORO.instance.<uuid>`) + `LSMultipleInstancesProhibited = false` flipped in the same Info.plist edit pass, then re-signed with our Developer ID (`Developer ID Application: Estevan Hernandez (82BSR56X5J)`) using a `disable-library-validation` entitlement so the re-signed parent (our team) can still load Roblox's Roblox-team-signed embedded helpers under Hardened Runtime. The existing `open -n -a` URL delivery path is preserved unchanged — re-signed copies are still LaunchServices-launched and still receive `kAEGetURL` normally.

The original plan rejected re-signing because commit `95d72fe` (2026-05-07) tried it and broke Roblox. Re-reading that commit message: the failure was specifically `--deep --sign -` (ad-hoc, deep) which stripped the team identifier and broke library validation for embedded helpers. The v2 recipe (no `--deep`, real Developer ID, with `disable-library-validation` entitlement) addresses each of those mistakes individually.

### Why this matters

This is a momentous-hurdle traversal worth recording, not a routine bugfix. The path from "v1 plan written and rejected re-sign on rumor" → "v1 PoC exposed an architectural wall in the planned approach" → "re-investigation showed the prior re-sign failure was specifically fixable" → "v2 validated end-to-end with real gameplay" turned a "this might be impossible" cookie-isolation problem into a smaller architecture than v1 had planned. The simpler-after-pivot pattern is worth pattern-matching against in future architecture work — a rejected approach should be re-validated when the actual blocker is found, not stayed-rejected on inherited rumor.

### Evidence

- **v1 plan (now superseded):** `docs/superpowers/plans/2026-05-11-per-instance-cookie-isolation.md` v1 (git history; current file is v2 written 2026-05-11)
- **v2 plan:** `docs/superpowers/plans/2026-05-11-per-instance-cookie-isolation.md` (current; see "PoC findings" section for the full evidence trail)
- **PoC artifact (deleted in Task 6):** `tools/spawn-poc/main.swift` — three-mode URL-delivery harness
- **PoC validation evidence:**
  - Re-signed `/tmp/roblox-resign-<uuid>.app` ran 12+ minutes of real gameplay
  - Zero anti-cheat / integrity / kick hits across `hyperion|byfron|anticheat|integrity|tamper|kicked|banned|invalid signature|unauthorized|moderation|forbidden` in Roblox's player log
  - Cookie jar at `~/Library/HTTPStorages/com.626labs.RORORO.instance.<uuid>.binarycookies` grew to 1961 bytes of real session state
  - The original `com.roblox.RobloxPlayer.binarycookies` mtime stayed put during the 12-minute re-signed session — complete cookie isolation confirmed
- **Prior re-sign failure rationale:** commit `95d72fe` (the attempt) and `3e9b9ea` (the revert) explain why the v1 plan rejected re-signing on rumor

### Open question — gating production shipping

The PoC validated re-signing with Este's Developer ID cert in keychain (local dev case). End users running the shipped DMG won't have that cert. Whether `--sign -` (ad-hoc) re-sign produces a viable Roblox launch with the entitlement intact is **untested**. Apple docs are ambiguous about whether entitlements take effect with ad-hoc signatures.

Resolution: scheduled as Task 4.5 in the v2 plan — a one-off PoC variant that swaps the Developer ID for `-` and tests the same flow. Outcome determines whether this fix ships to the public DMG or stays a local-dev improvement until distribution is solved.

### Tag

`architectural-pivot` · `cookie-isolation` · `multi-instance` · `momentous-hurdle`

---

## Entry 2 (only land after Task 4.5 completes) — outcome of ad-hoc re-sign distribution PoC

**[Pending — fill in after Task 4.5 runs]**

**Type:** Architectural decision (shipping gate)
**Project:** rororo-mac
**Date:** TBD

Capture: did `--sign -` ad-hoc + entitlement deliver a working Roblox? If yes, log the decision to ship cookie isolation in the public DMG. If no, log the decision to keep it local-dev-only and link to the next-step ticket for solving distribution.
