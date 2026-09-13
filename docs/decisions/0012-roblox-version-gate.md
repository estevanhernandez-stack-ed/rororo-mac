# ADR 0012 — Gate multi-instance launches on Roblox version parity

**Date:** 2026-09-13
**Status:** Accepted (branch `fix/support-remediation`)
**Origin:** Support email, reproduced locally with a 0.726 install against a 0.738 live version

## Background

Multi-instance copies `/Applications/Roblox.app` per launch (ADR 0009). When that bundle is behind Roblox's live MacPlayer version, each copy's `RobloxPlayer` runs its protocol-launch update check, decides it's stale, and spawns the embedded `RobloxPlayerInstaller.app`. Captured on 2026-09-13:

```
09:59:22  installer (copy A)  Single instance lock acquired.
09:59:29  installer (copy B)  ERROR acquireSingleInstanceLock: Another instance is already running.
09:59:30  installer (copy A)  moved ~/Library/Roblox/UnzippedBundle/RobloxPlayer.app to /Applications/Roblox.app
09:59:30  installer (copy A)  relaunched /Applications/Roblox.app -isInstallerLaunch true
```

The lock lives at `$TMPDIR/com.roblox.player.installer.lock` and is keyed by product, not bundle ID, so per-instance bundle IDs don't isolate it. Copy B shows Roblox's "Another Installer is already running." dialog. Copy A's installer relaunches the canonical single-instance app, so the account and launch URL for copy A are lost as well. Neither outcome is recoverable from inside the copy.

## Decision

Add `RobloxVersionGate` (actor) and run `preflight()` as step 0 of `RobloxLauncher.launch` when multi-instance is ON:

- Local: `CFBundleShortVersionString` of `/Applications/Roblox.app`.
- Live: `https://clientsettingscdn.roblox.com/v2/client-version/MacPlayer` → `version`. Same endpoint Roblox's installer uses. Cached 5 minutes so a group launch costs one request.
- Mismatch → throw `LauncherError.robloxUpdateRequired(local:live:)`. The message names both versions and the fix: open Roblox once from `/Applications`, let it update, retry.
- Anything indeterminate (Roblox missing, endpoint down, bad JSON) → `.unknown` → launch proceeds. A blocked launch on a flaky connection is a worse regression than the occasional installer dialog.

Multi-instance OFF is not gated: it opens the canonical app, which self-updates correctly.

## Amendment 2026-09-13 — RORORO drives the update after all

The "block and tell" v1 shipped in PR #8 the same day and was overruled on review: a launcher that knows exactly what's wrong should fix it, not hand the user a chore. `RobloxUpdateDriver` (actor) now backs an **Update Roblox** button on the Launch As alert and runs unprompted on the `roblox-player://` link path:

1. `open -a /Applications/Roblox.app` with no URL. The canonical player runs its own update check, spawns its installer, which replaces the bundle and relaunches the canonical player.
2. Poll `CFBundleShortVersionString` every 2 s until it equals live (180 s timeout).
3. Terminate `com.roblox.RobloxPlayer` only (never the `com.626labs.RORORO.instance.*` copies), since the relaunched canonical player is an empty window holding the singleton semaphore.
4. Report `.updated`; the caller replays the original launch through the same recursion the TCC-preflight and relogin alerts use.

Concurrent callers (a group launch where every account tripped the gate) join one in-flight run. Failures (`timedOut`, `liveUnknown`, `openFailed`) surface as the plain "Launch failed" alert with the manual fallback in the text. The gate itself is unchanged.

## Alternatives considered

**RORORO drives the update.** Originally rejected for v0.7.x (see amendment above — adopted the same day).

**Compat-feed `knownGoodRobloxVersion`.** Already in `RobloxCompatConfig` but unused; would require a manual push per Roblox release. The live endpoint is authoritative and free.

**Compare `clientVersionUpload` instead of `version`.** The bundle plist only carries the dotted version; the upload hash isn't available locally without parsing Roblox's internal files.

## Consequences

- One extra HTTPS request per five minutes of launching. Timeout 8 s, off the main actor.
- `LauncherError` now conforms to `LocalizedError` so the inbound-link path (`launchAsAccount` → `lastError`) shows the same message as the per-row alert.
- Runbook §5.9 documents the failure mode and detection. `docs/user/uninstall-and-reset.md` carries the user-facing fix.

## Verification

- `RobloxVersionGateTests` × 12: pure verdict, wire decode, plist read against a fake bundle, preflight stale / current / endpoint-down (fail-open) via `URLProtocolStub`, TTL cache, message contents.
- Manual: the reproduction above, run with two ad-hoc re-signed copies of a stale bundle, before the gate existed.
