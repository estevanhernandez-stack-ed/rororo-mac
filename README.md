# RORORO Mac

_Mac-native multi-launcher for Roblox — run multiple Roblox clients on macOS, signed in as different saved accounts._

[![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-f22f89?style=flat-square)](https://www.apple.com/macos/)
[![Stack: Swift / SwiftUI](https://img.shields.io/badge/stack-Swift%20%2F%20SwiftUI-17d4fa?style=flat-square)](https://developer.apple.com/swift/)
[![License: MIT](https://img.shields.io/badge/license-MIT-17d4fa?style=flat-square)](#license)

> **"Roblox" is a trademark of Roblox Corporation.** RORORO is not affiliated with, endorsed by, or sponsored by Roblox Corporation. We use the term to describe compatibility — this app launches the official Roblox client unmodified. A 626 Labs product.

Sibling to [ROROROblox](https://github.com/estevanhernandez-stack-ed/ROROROblox) (Windows). Same product, different platform; the auth-ticket → launcher URI flow is byte-identical so accounts can roam between OSes later.

---

## Install

> **Status:** v0.1.0 not yet shipped. Bootstrap (Sparkle EdDSA keypair, Apple Developer ID cert, notarization creds, GitHub Pages enablement) is the gate before tagging. See [`tools/release/README.md`](tools/release/README.md).

Once shipped: download the latest `RORORO.dmg` from [Releases](https://github.com/estevanhernandez-stack-ed/rororo-mac/releases), open it, drag `RORORO.app` to `/Applications`, launch. Notarized + signed by Apple — no Gatekeeper prompts. Auto-updates via Sparkle on next launch.

## What it does

- **One-click multi-instance.** Toggle in the menu-bar tray runs the per-launch app-copy + `sem_unlink` recipe so multiple Roblox clients run side by side. Same outcome as MultiBloxy on Windows; different mechanism (POSIX named semaphore instead of Windows mutex).
- **Saved Roblox accounts.** Add your alts once via an embedded login window. Click *Launch As* to spawn each one.
- **Keychain-backed cookie vault.** Saved cookies live in your login Keychain (`kSecAttrAccessibleWhenUnlocked` + `kSecAttrSynchronizable: false`). They never leave your Mac and never sync to iCloud.
- **Per-game launch routing.** Set a default Roblox game URL once; *Launch As* lands every alt in that game.
- **Menu-bar tray.** State-coloured ring shows multi-instance status at a glance (cyan = on, slate = off, magenta = error).
- **Sparkle auto-update.** EdDSA-signed appcast hosted at `https://estevanhernandez-stack-ed.github.io/rororo-mac/appcast.xml`. Drift-compatible with future Roblox-side changes.
- **No telemetry.** Anonymous GitHub Releases download counts only.

## How to use

1. Open RORORO from `/Applications` (or the menu-bar tray icon if it's already running).
2. Click **+ Add Account**, log in with the Roblox account you want to save. The login happens entirely inside Roblox's own page — your password never touches our process.
3. Repeat for each alt.
4. Toggle **Multi-Instance: ON** in the toolbar or tray menu.
5. Click **Launch As** next to any saved account. Repeat for any other account to spawn another client.

The first time you Launch As, set a default Roblox game URL in Settings. Paste any Roblox game's `roblox.com/games/...` link — that's where Launch As will land your alts unless you override per-launch via the ⋯ menu.

## What gets stored on your Mac

| Where | What |
|---|---|
| `~/Library/Application Support/RORORO/accounts.json` | Public account profile data (display name, user ID, avatar URL, last-launched timestamp). Plain JSON — no secrets. |
| Login Keychain (`com.626labs.rororo-mac.account-cookie`) | Roblox `.ROBLOSECURITY` session cookies. One Keychain item per account, keyed by Roblox userId. Never syncs to iCloud. |
| `~/Library/Application Support/RORORO/instances/` | Per-launch copies of `Roblox.app`. Cleaned up automatically (entries older than 24h removed on next boot). |
| `~/Library/Preferences/com.626labs.rororo-mac.plist` | UI preferences — multi-instance toggle, default game URL, saved URL-scheme handler bundle ID. |

## What about my Roblox password?

Short version: **RORORO never sees it.**

Long version: when you click *Add Account*, RORORO opens a `WKWebView` pointed at `https://www.roblox.com/login`. The login page is Roblox's own — same HTML, same form, same HTTPS connection your browser would make. Your keystrokes go from the embedded browser straight to Roblox's servers. RORORO is the window frame, not the form handler. The `WKWebView` runs against a **non-persistent data store** — when the sheet closes, all cookies it scraped evaporate.

What we **do** capture, after Roblox confirms a successful login, is the `.ROBLOSECURITY` session cookie that Roblox sets in our private cookie store. That cookie is what we hand back to Roblox during *Launch As* to start a session as you. Before we hand it to anyone else, we put it in the macOS login Keychain — encryption tied to your specific user account on your specific machine. Once it's in Keychain, it never appears in plaintext on disk again.

We never log the cookie value. We never send the cookie to anyone other than Roblox. It exists in plaintext only briefly in memory during a single *Launch As* operation, then goes back to Keychain.

**No cookies are ever written to disk in plaintext. No data leaves your Mac except Roblox-side calls during launch — the same calls Roblox.com makes from your browser.**

## Tech stack

- **Swift / SwiftUI** (macOS 14+)
- **WebKit** (`WKWebView` + `WKHTTPCookieStore` for login capture)
- **Security.framework** (`SecItem` Keychain access)
- **AppKit** (`NSWorkspace` for URL scheme + multi-app launch, `NSStatusItem` for tray)
- **POSIX `sem_unlink`** (the multi-instance break — `Darwin` import)
- **Sparkle 2.x** (auto-update via signed appcast)
- **XCTest** (unit + integration coverage — 89 tests at v0.1.0)
- **XcodeGen** (project source-of-truth in `App/project.yml`; `.xcodeproj` is gitignored)

## Provenance

The multi-instance technique combines two prior public-source approaches:

- **MultiBloxy** by [Zgoly](https://github.com/Zgoly/MultiBloxy) — Windows mutex hold (`Local\ROBLOX_singletonEvent`).
- **Insadem multi-roblox-macos** — POSIX `sem_unlink("/RobloxPlayerUniq")` + per-launch `cp -a /Applications/Roblox.app …` + `LSMultipleInstancesProhibited` flip.

RORORO Mac is **not a fork** — it's a clean reimplementation in Swift with substantially expanded scope (account management, structured launch flow, error handling, signed distribution). No code is copied from either project. See [`PROVENANCE.txt`](PROVENANCE.txt) for SHA-256 hashes of the reference binaries.

## Roblox-side caveats

- Roblox / Hyperion has stated multi-instancing "may be considered malicious behavior." Risk of a ban appears low because we don't inject into or modify the Roblox client — we only call a public POSIX function (`sem_unlink`) and copy a public app bundle. But it is non-zero. Don't run this on accounts you can't afford to lose.
- The auth-ticket endpoint contract is what we depend on. If Roblox changes it, multi-instance launches will start failing. The Diagnostics view surfaces the canonical semaphore name; bumping it is a one-line code change.

## Building from source

```sh
# Open in Xcode
cd App && xcodegen generate && xed RORORO.xcodeproj

# Build from CLI
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO build

# Run tests
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
  -destination 'platform=macOS,arch=x86_64'
```

## Documentation

- **Privacy policy:** [`docs/PRIVACY.md`](docs/PRIVACY.md)
- **Technical spec:** [`docs/spec.md`](docs/spec.md)
- **PRD:** [`docs/prd.md`](docs/prd.md)
- **Security audit:** [`docs/security-audit.md`](docs/security-audit.md)
- **Release pipeline + bootstrap:** [`tools/release/README.md`](tools/release/README.md)
- **Repo conventions for AI agents:** [`CLAUDE.md`](CLAUDE.md)

## Why "RORORO"?

The name is a stutter spelling of **Roblox** — *RO RO RO blox* — visualizing what the app does: spawn three (or more) Roblox clients side by side. Sibling to RORORO Windows; same product, different platform.

The brand DNA is 626 Labs — neon cyan + magenta on deep navy, geometric type, builder-to-builder voice. *Imagine Something Else* is the umbrella; **Mac-native multi-Roblox launcher** is the product.

> "Roblox" and the Roblox logo are trademarks of Roblox Corporation. RORORO is an independent third-party tool, not affiliated with, endorsed by, or sponsored by Roblox Corporation. The trademarked term is used solely to describe compatibility with the Roblox platform.

## License

Source code is **MIT-licensed** © 626 Labs LLC. See [`LICENSE`](LICENSE).
