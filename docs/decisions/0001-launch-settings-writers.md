# ADR 0001 — Launch-time settings writers (FFlags + FramerateCap)

**Date:** 2026-05-08
**Status:** Accepted
**Slope:** A (FFlag injection + FPS throttle), from `/vibe-iterate` session 2026-05-07/08
**Spike:** AppleBlox source dive (`github.com/AppleBlox/appleblox`), three subagents — Pathfinder / Schema Hunter / Lifecycle Auditor

## Background

RORORO Mac needs to apply launch-time settings to two distinct Roblox surfaces so a user can run multiple Roblox instances at a throttled framerate (the headline use case the Windows team cracked):

1. **Framerate cap** — Roblox defaults to 60fps; multi-instancing thrashes the GPU at that cap × N.
2. **FFlag overrides** — graphics API selection, quality presets, render resolution (AppleBlox-style ride-alongs that survive Hyperion's allowlist).

The AppleBlox spike confirmed the macOS write surfaces and surfaced three substrate-level decisions plus a multi-instance reality that shape the implementation.

## Decision 1 — FramerateCap path: surgical XML edit of `~/Library/Roblox/GlobalBasicSettings_<N>.xml`

**Decision:** RORORO writes `FramerateCap` by surgically editing the highest-numbered `GlobalBasicSettings_*.xml` file under `~/Library/Roblox/`. All other elements in the file are preserved verbatim. Writes are atomic (`Data.write(.atomic)`).

**Rationale:** Roblox's Hyperion allowlist locked the FFlag write surface — `DFIntTaskSchedulerTargetFps` and equivalent framerate flags are no longer honored, in either direction. `GlobalBasicSettings_<N>.xml` is the user-prefs file Roblox writes when in-game settings change; it lives on a separate read channel the engine loads at startup. Sober (Linux Flatpak) and the Windows team confirmed this path; verified on this machine that `~/Library/Roblox/GlobalBasicSettings_13.xml` line 22 contains `<int name="FramerateCap">60</int>`.

**Schema-version glob:** filename is matched as `GlobalBasicSettings_<N>.xml`, highest `N` wins. Insurance against Roblox bumping `_13` → `_14` mid-flight.

**Consequences:** Surgical XML edits via `XMLDocument` preserve sibling user settings (graphics quality, sensitivity, fullscreen). The cap value is freeform — values from 20 (multi-instance throttle) to 9999 (the Windows unlock test) all round-trip.

## Decision 2 — FFlag injection path: JSON write inside the Roblox.app bundle

**Decision:** RORORO writes its FFlag dictionary to `<RobloxBundle>/Contents/MacOS/ClientSettings/ClientAppSettings.json` via atomic write. Bundle path is resolved via Spotlight `mdfind kMDItemCFBundleIdentifier == 'com.roblox.RobloxPlayer'` (with a 1.5s timeout), then `/Applications/Roblox.app`, then `~/Applications/Roblox.app` — first one whose `Info.plist` confirms a `com.roblox.*` bundle identifier wins.

**Rationale:** AppleBlox spike confirmed Roblox's macOS installer drops the .app user-writable (no admin prompt). The `Contents/MacOS/ClientSettings/` subdir is user-data, not a code-signed resource — writes there don't break the binary's signature. There is no user-Library FFlag path the Roblox player reads on macOS; the bundle is the only sink.

**Posture diverges from AppleBlox in three ways** (each fixing a real Heisenbug or footgun in their implementation):

- **Atomic write (tmp + rename) instead of direct overwrite.** AppleBlox's direct overwrite is the single most-likely race condition in their codebase — multiple AppleBlox processes write simultaneously without a flock; last writer wins, partial writes are possible if either process crashes mid-write. `Data.write(.atomic)` keeps the previous file intact on failure.
- **Hash-detect user hand-edits.** Before each write we compare the on-disk file's SHA-256 to our last-known hash. A divergence means the user hand-edited outside RORORO; the policy enum (`stomp` / `preserveAndThrow`) lets the caller decide. AppleBlox unconditionally `rm -rf`s the entire `ClientSettings/` directory on every launch, silently nuking user hand-edits.
- **PID-exit cleanup, not setTimeout.** AppleBlox cleans up via `setTimeout(rm, 5000)` after Roblox spawns — a Heisenbug on slow Macs / cold starts where the rm fires before Roblox parses the file. We observe Roblox process termination via `NSWorkspace.didTerminateApplicationNotification` and only clean up when no Roblox instance is running; a `willTerminateNotification` fallback handles the RORORO-quit-with-Roblox-already-gone case.

**Consequences:** The bundle write is durable across Roblox auto-updates (Roblox's updater overwrites `Contents/MacOS/RobloxPlayer` and friends but typically leaves `ClientSettings/`). RORORO uninstall without quitting cleanly leaves the last-written `ClientAppSettings.json` in place — documented limitation; users can hand-delete or run a future "reset Roblox FFlags" UI.

## Decision 3 — Multi-instance reality: `FramerateCap` is per-user, not per-instance

**Decision:** Setting `FramerateCap=20` caps every running Roblox instance at 20fps uniformly. RORORO's headline use case (multi-instance throttle for GPU sustainability) is uniform-cap, so this matches user intent.

**Rationale:** `~/Library/Roblox/GlobalBasicSettings_<N>.xml` is per-macOS-user, not per-running-instance. Roblox reads it at engine startup; all subsequently-spawned instances share whatever value is on disk at their startup time.

**Consequences:** Per-account divergent caps (account A at 60fps, account B at 20fps simultaneously) are not achievable through this writer alone. Future per-account work (Slope A's A3) will need a per-process throttle (macOS `taskpolicy`, `posix_spawnattr_set_qos_class_np`, or similar) for the diverged case. For now, accepted reality: Roblox-wide FPS, all instances uniform.

## Decision 4 — Defaults are no-op until the user opts in

**Decision:** `LaunchSettingsStore` defaults — `framerateCap = nil`, `fflags = [:]`. Until the user explicitly sets a value, RORORO's launch flow does not touch either Roblox file.

**Rationale:** Existing launch flow byte-identical for users who don't engage the new feature. Risk-averse default — every user who installs the app gets unchanged behavior unless they choose otherwise.

**Consequences:** First-time users see no change. Power users opt in via Settings. The two writers' fail-soft posture (NSLog + continue on error) means even a misconfigured opt-in doesn't break launching.

## Implementation map

| Layer | File | What it does |
| --- | --- | --- |
| Domain | `App/RORORO/Domain/GlobalSettingsWriter.swift` | XML surgical edit + version glob |
| Domain | `App/RORORO/Domain/RobloxBundleResolver.swift` | Spotlight + fallback bundle resolution |
| Domain | `App/RORORO/Domain/ClientSettingsWriter.swift` | Atomic JSON write + hash-detect + cleanup |
| Domain | `App/RORORO/Domain/LaunchSettingsStore.swift` | UserDefaults-backed snapshot + `AnyCodableValue` |
| Domain | `App/RORORO/Domain/RobloxLauncher.swift` | Step 4.5 hook in `launch(account:target:)` |
| Domain | `App/RORORO/Domain/MultiInstanceCoordinator.swift` | `NSWorkspace.didTerminateApplicationNotification` cleanup observer |
| UI | `App/RORORO/UI/SettingsView.swift` | "Frame rate" section: enable toggle + value picker |
| Tests | `App/ROROROTests/{GlobalSettingsWriter,ClientSettingsWriter,RobloxBundleResolver,LaunchSettingsStore}Tests.swift` | 30 unit tests, no real Roblox install required |

## Open follow-ups

- A1 presets (graphics API switch, quality presets, render resolution) — UI surface deferred; substrate is in.
- A3 per-account graphics presets + per-process throttle for divergent caps — separate slope.
- Reset-FFlags UI button (calls `ClientSettingsWriter.cleanup()` directly) — for power users who want to revert without quitting RORORO.
