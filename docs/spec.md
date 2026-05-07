# RORORO Mac — Technical Spec

## §1 Overview

RORORO Mac is a Mac-native multi-Roblox launcher. Two surfaces: an account vault (saved Roblox cookies) and a multi-instance coordinator (the per-launch app-copy + `sem_unlink` recipe that lets multiple Roblox clients run side by side on macOS).

Sibling to RORORO Windows; same product, different OS-specific multi-instance technique. The auth-ticket → launcher URI flow is byte-identical between the two ports — accounts could roam between Mac and Windows in a future release without protocol changes.

## §2 Goals and non-goals

**Goals:**
- One-click multi-Roblox on macOS 14+, signed and notarized.
- Account vault that never lets the cookie touch plaintext disk.
- No telemetry. Ever.
- Native Apple APIs only — no Electron, no Tauri, no cross-platform retrofit.

**Non-goals (v0.1.0):**
- Anti-detection logic. We use only public POSIX calls; nothing hidden, nothing injected.
- Cross-platform account import/export (the wire shape is compatible with Windows; the UX lands later).
- Mac App Store distribution (signed-DMG via GitHub Releases is the v0.1.0 channel; MAS comes later).

## §3 Stack

- macOS 14.0+ deployment target.
- Swift 5.9 / SwiftUI for the app.
- WebKit (`WKWebView` + `WKHTTPCookieStore`) for login capture.
- Security.framework (`SecItem`) for Keychain.
- AppKit (`NSWorkspace`, `NSStatusItem`, `LaunchServices`) for URL-scheme handling, multi-app launch, and tray.
- POSIX `sem_unlink` via `Darwin` for the multi-instance break.
- Sparkle 2.6+ for auto-update.
- Apple Developer ID + notarization for distribution; no App Sandbox (App Sandbox blocks the `LSSetDefaultHandlerForURLScheme` + `Process.run("/usr/bin/open")` paths the coordinator needs).

## §4 Architecture

Three layers, top-to-bottom:

```
UI (SwiftUI)
  ├── ContentView, AccountsListView, AddAccountSheet, LaunchTargetEditor,
  │   SettingsView, DiagnosticsView, AboutView, UpdateSettingsView
  ├── TrayController (NSStatusItem)
  └── Theme (626Labs design tokens)

Domain
  ├── AccountStore (@MainActor @Observable)        — accounts.json + Keychain
  ├── KeychainStore (SecItem wrapper)              — generic-password storage
  ├── Account                                      — public profile struct
  ├── CookieCapture (WKWebView wrapper)            — non-persistent login UI
  ├── RobloxApi (auth-ticket + user-profile + avatar) — URLSession + URLProtocol seam
  ├── RobloxLauncher (URI builders + launch())     — orchestrator on .shared
  ├── LaunchTarget (discriminated union + parser)  — byte-identical to Windows port
  ├── FavoriteGameStore                            — default game URL
  ├── SemaphoreBreaker                             — sem_unlink wrapper
  ├── RobloxAppCopier                              — per-launch app copy + plist flip
  ├── URLSchemeHandler                             — claim/restore roblox-player://
  ├── MultiInstanceState (@MainActor @Observable)  — UI state mirror
  ├── MultiInstanceCoordinator (singleton)         — the recipe orchestrator
  └── UpdaterHost (Sparkle bootstrap)              — SPUStandardUpdaterController owner

Native APIs (Apple SDK)
  ├── Foundation, AppKit, SwiftUI, WebKit, Security, Sparkle
  └── POSIX (Darwin) — sem_unlink only
```

Strict layer direction: UI imports Domain; Domain imports Native APIs. Domain types stay free of UI imports.

## §5 The recipe (load-bearing)

For each launch:

1. Coordinator receives a `roblox-player:` URL (from .onOpenURL — claimed via Info.plist `CFBundleURLTypes` + `LSSetDefaultHandlerForURLScheme`).
2. If multi-instance is OFF: hand the URL straight to `/Applications/Roblox.app` via `NSWorkspace.shared.open(url, withApplicationAt:)`.
3. If multi-instance is ON:
   a. `RobloxAppCopier.copyAppForInstance()` — `cp -a /Applications/Roblox.app → ~/Library/Application Support/RORORO/instances/<uuid>.app/`. Read `Contents/Info.plist` via `PropertyListSerialization`, set `LSMultipleInstancesProhibited = false`, write back.
   b. `SemaphoreBreaker.breakRobloxSingleton()` — `sem_unlink("/RobloxPlayerUniq")`.
   c. `NSWorkspace.shared.open([url], withApplicationAt: copy, configuration: { createsNewApplicationInstance = true })` — spawn the copy.
   d. Race-buffer break: `sem_unlink` once more, in case Roblox's launch path recreated the semaphore between (b) and (c).

The "Launch As" UI button calls `RobloxLauncher.shared.launch(account:target:)` which:
- Pulls the cookie from Keychain via AccountStore.
- Hits `auth.roblox.com/v1/authentication-ticket` (CSRF-dance: 403 with `x-csrf-token`, retry with `X-CSRF-TOKEN` header, read `RBX-Authentication-Ticket`).
- Builds the `roblox-player:1+launchmode:play+gameinfo:<ticket>+placelauncherurl:<encoded>+browsertrackerid:<id>+robloxLocale:en_us+gameLocale:en_us` URI.
- Hands the URI to `MultiInstanceCoordinator.shared.handleIncomingURL(url)` — same path as a roblox.com Play click.

## §6 Error handling

| Bucket | Surface |
|---|---|
| Cookie expired (401) | `RobloxApi.APIError.cookieExpired` → UI banner: "This account's login expired. Remove and re-add." |
| Roblox 5xx | `.transient(status:)` → "Roblox is having trouble. Try again." |
| Cookie missing in Keychain | `LauncherError.cookieMissing(userId:)` → "No cookie stored. Remove and re-add." |
| `/Applications/Roblox.app` missing | `RobloxAppCopier.CopyError.sourceMissing` → "Roblox is not installed at /Applications/Roblox.app." |
| URL scheme claim failed | `MultiInstanceState.lastError` set; tray ring goes magenta |
| Sparkle bootstrap incomplete | `UpdaterHost.bootIfNeeded()` runs with `startingUpdater: false` until the four secrets land |

## §7 Testing

89 XCTest tests at v0.1.0. Coverage:

- `SemaphoreBreakerTests` — `sem_unlink` wrapper.
- `KeychainStoreTests` — SecItem wrapper via `inMemoryOverride`.
- `LaunchTargetTests` — `fromUrl` + `tryParseShareLink` (table-driven; ported byte-identical from RORORO Windows).
- `RobloxApiTests` — `getAuthTicket` CSRF dance + `getUserProfile` + `getAvatarHeadshotURL` via `URLProtocolStub`.
- `RobloxLauncherTests` — URI builders snapshot-tested byte-identical to Windows.
- `RobloxAppCopierTests` — copy-and-flip path against a fake .app fixture; real Roblox.app integration test gates on its presence.
- `AccountStoreTests` — JSON + Keychain split via `inMemoryOverride`.

## §8 Distribution

- Apple Developer ID signed + notarized DMG via GitHub Releases.
- Sparkle 2.x for auto-update; EdDSA-signed appcast hosted at `https://626labs.github.io/rororo-mac/appcast.xml`.
- Tag-driven: `git tag v0.1.0 && git push origin v0.1.0` triggers `.github/workflows/release.yml`.
- Bootstrap (4 steps owed to Estevan before the first tag): see [`tools/release/README.md`](../tools/release/README.md).

## §9 Decisions log

Significant decisions log to the **626Labs Dashboard** via MCP (`mcp__626Labs__manage_decisions log`). See `CLAUDE.md` for the bar.
