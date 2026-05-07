# RORORO Mac — Product Requirements

## Why

People run multiple Roblox accounts. On Windows, MultiBloxy + several other tools solve this by holding the singleton mutex. On macOS, the same problem is solved by `sem_unlink` + a per-launch app copy — but the only public-source implementations are unsigned Go CLI tools (Insadem, iigordev, Avaluate). No polished, signed/notarized desktop app exists.

626 Labs ships ROROROblox on Windows. RORORO Mac is the matching Mac-native product.

## Who

- Roblox players running multiple accounts (alts, family accounts, dev/test accounts).
- Specifically: people on macOS 14+ who don't want to install a CLI binary, edit `Info.plist` by hand, or run unsigned community tools that Gatekeeper warns about.

## Done definition

`v0.1.0` is shippable when:

- A user can install `RORORO.dmg`, drag to `/Applications`, and launch without a Gatekeeper warning (signed + notarized).
- A user can add 2+ Roblox accounts via the embedded login flow.
- A user can toggle multi-instance ON and click *Launch As* twice to spawn two simultaneous Roblox clients.
- The multi-instance toggle persists across app relaunch.
- The auto-updater (Sparkle) checks for updates daily, prompts on a new release, downgrades cleanly on rollback (mark-as-prerelease in GitHub Releases).
- No analytics, no telemetry, no third-party SDKs.

Not v0.1.0:
- Mac App Store distribution.
- Cross-platform account import (Windows ↔ Mac).
- Per-account WebView profile isolation (today: shared non-persistent store, wiped per sheet).
- Crash reporting (today: no logs leave the Mac).
- Squad Launch / Friend Follow surfaces (the API is ported but the UI lands at v0.2).

## Constraints

- Native Apple APIs only. No Electron, no Tauri, no cross-platform retrofit.
- macOS 14+ (Sparkle 2.6 + WKWebView modern data-store APIs).
- Apple Developer ID signed + notarized. App Sandbox is OFF (it blocks `LSSetDefaultHandlerForURLScheme` and `Process.run("/usr/bin/open")` — load-bearing for the recipe).
- No anti-detection logic. We call public POSIX functions and copy public app bundles. Any change to that posture is a logged decision and a user-facing disclosure.
- No telemetry. Anonymous GitHub Releases download counts only.

## User stories

| As a... | I want... | So that... |
|---|---|---|
| Player with 3 alts | one-click *Launch As* for each saved account | I don't have to log in/out repeatedly |
| Player worried about cookies | proof that my Roblox password isn't stored | I can trust the app with my session |
| Mac user paranoid about Gatekeeper | a signed + notarized DMG | I'm not clicking through scary warnings |
| Player on a flaky network | retry path for transient Roblox 5xx | a momentary blip doesn't lose my launch |
| Power user | a way to override the default game per launch | I can pop a friend into a different game without changing global settings |

## Acceptance scenarios (manual smoke)

The list `tools/release/README.md` references for pre-tag verification:

1. Fresh DMG install on a clean Mac — drag to `/Applications`, launch. No Gatekeeper warning.
2. Click *+ Add Account*. WKWebView loads roblox.com/login. Log in. Sheet closes; account row appears with avatar.
3. Click *+ Add Account* again with a different account. Two rows visible.
4. Toggle multi-instance ON in the toolbar (or tray menu).
5. Set a default game URL in Settings.
6. Click *Launch As* on Account A. Roblox window 1 opens.
7. Click *Launch As* on Account B. Roblox window 2 opens **alongside** the first. Both stay running.
8. Quit RORORO. Tray icon disappears. URL scheme handler restores to `/Applications/Roblox.app` (or whatever was previous).
9. Re-launch RORORO. Saved accounts persist. Multi-instance toggle persists.
10. Tag `v0.0.x → v0.1.0`. GitHub Actions runs end-to-end. DMG attached to Release. `appcast.xml` regenerated. `gh-pages` published.

## Open questions

- **Compat-config remote feed.** RORORO Windows has a `roblox-compat.json` hosted as a Gist that the app fetches at startup so we can ship "the semaphore renamed" updates within hours. Do we ship the same on Mac at v0.1.0, or wait for the first Roblox-side rename event to motivate it?
- **Per-account WKWebView profile isolation.** Currently all accounts share the same `.nonPersistent()` data store; we wipe between sheets. Per-account profile isolation gives stronger guarantees but requires per-account `WKWebsiteDataStore.identifier` plumbing. Defer or ship?
- **NSStatusBar visibility on first launch.** macOS sometimes hides newly-installed status items behind notch/menu-bar collisions. Do we surface a one-time "Find me in the menu bar" hint?
