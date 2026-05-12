# RORORO Mac

> **Persona:** This repo inherits **The Architect** from `~/.claude/CLAUDE.md`. No need to re-establish — just adds project context below.

RORORO Mac is the Mac-native multi-Roblox launcher. Sibling to RORORO Windows (C# / .NET 10 / WPF, lives at `github.com/estevanhernandez-stack-ed/ROROROblox`). Same product, different platform; the auth-ticket → launcher-URI flow is byte-identical so accounts can roam between OSes later.

**Status (2026-05-08):** Phases 1–6 shipped — Domain layer (Keychain vault, multi-instance coordinator, RobloxLauncher, URL-scheme handler), UI/Theme, and signed-DMG/PKG release pipeline with Sparkle 2.x auto-update. Currently iterating on launch-time settings writers (Slope A: FFlag injection + FramerateCap throttle). See `docs/decisions/0001-launch-settings-writers.md`. Plan-of-record for any subsequent phases is `~/.claude/plans/plan-mac-native-woolly-pascal.md`.

## Tech Stack

- **App:** Swift / SwiftUI. Native Apple APIs only — `WKWebView` for cookie capture, `Security.framework` (Keychain) for the vault, `LSSetDefaultHandlerForURLScheme` for `roblox-player://`, POSIX `sem_unlink` for the multi-instance break.
- **Build:** XcodeGen → `App/project.yml` is the source of truth; the generated `.xcodeproj` is gitignored.
- **Distribution:** Apple Developer ID signed + notarized DMG via GitHub Releases. Sparkle 2.x for auto-update. Notarize-in-CI via GitHub Actions. (Lands at Phase 6.)
- **Deployment target:** macOS 14.0.

## Hard rules

- **No anti-detection logic.** `sem_unlink` is a public POSIX call; that's all we use. No injection, no patching, no observation evasion.
- **No telemetry.** GitHub Releases anonymous download counts only.
- **No secrets in repo.** Sparkle EdDSA private key + Apple Developer ID cert + notarization creds in 1Password / GitHub Secrets only. `.env.example` is placeholder-only.
- **No password capture.** WKWebView shows Roblox's own login form. We capture only the `.ROBLOSECURITY` cookie post-login.
- **No `NSEvent` monitors / Sparkle boot in `App.init()`.** Defer to `.onAppear`. The trap: silent loss of mouse-event delivery + dim traffic lights. Documented in macRo's `App/macRo/App.swift` header.
- **No `CFBundleDocumentTypes` registration.** macRo's regression note explains why (drop-target hijacks the entire main window).
- **Don't tag `v0.1.0` from Claude.** That's a human-only step after the four bootstrap secrets are uploaded.
- **Bundle-ID-keyed storage is shared across all running per-instance copies unless bundle IDs differ.** macOS keys cookies (`~/Library/HTTPStorages/<bundle>.binarycookies`), NSUserDefaults (`~/Library/Preferences/<bundle>.plist`), HTTPStorages, and WebKit storage by `CFBundleIdentifier`, not bundle path. Multi-instance isolation requires each per-instance copy to have a unique bundle ID — `BundleIDRewriter` handles this at copy time + re-signs with our chosen identity (ad-hoc `--deep` by default) so amfid accepts the spawn. Don't add a launch path that bypasses `BundleIDRewriter`. Don't reuse a bundle ID across accounts. See ADR 0009.

## What's where

| Path | What it is |
| --- | --- |
| `README.md` | Public-facing intro. |
| `CLAUDE.md` | This file. |
| `LICENSE` | MIT. |
| `App/` | Swift / SwiftUI app source. XcodeGen project at `App/project.yml`; the `.xcodeproj` is gitignored — regen with `cd App && xcodegen generate`. |
| `App/RORORO/App.swift` | `@main` entry point. Deferred-init pattern: never install event-coupled services from `App.init()`. |
| `App/RORORO/Domain/` | Native services + domain logic. Populated in Phases 1–4. |
| `App/RORORO/UI/` | Views + tray. Populated in Phase 5. |
| `App/RORORO/Theme/` | 626Labs design tokens (cyan / magenta / navy / teal). Lands at Phase 5. |
| `tools/release/` | Notarization + appcast scripts. Lands at Phase 6 (copied from macRo). |
| `.github/workflows/` | CI + tag-driven release. Lands at Phase 6. |
| `docs/` | spec, prd, PRIVACY, security audit. Lands at Phase 7. |

## Conventions

- **Commits:** Conventional commits — `feat`, `fix`, `docs`, `refactor`, `chore`, `test`, `build`, `style`. One commit per phase.
- **Style (Swift):** Swift API Design Guidelines. Domain types stay free of UI imports. Threading: app-side work on main; multi-instance coordinator's I/O on a dedicated background queue (lands at Phase 3).
- **Branch hygiene:** `main` always shippable.

## Common tasks

| You want to… | Path / command |
| --- | --- |
| Open the app in Xcode | `cd App && xcodegen generate && xed RORORO.xcodeproj` |
| Build from CLI | `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO build` |
| Run tests | `xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test -destination 'platform=macOS,arch=x86_64'` (lands at Phase 1) |

## Decisions log

Significant decisions log to the **626Labs Dashboard** via MCP (`mcp__626Labs__manage_decisions log`). Tag with the bound project ID. The bar: *would future-you (or someone asking "why this approach?") want to know this in 3–6 months?*

Especially:
- Schema / vault format changes (Keychain attribute choices, `.ROBLOSECURITY` storage shape).
- Multi-instance recipe changes (semaphore name overrides via remote compat config, copy-vs-symlink decisions).
- Sparkle EdDSA key handling (one-way break — losing the private key forces every existing client off the update channel).
- URL scheme claim/restore semantics (the user's previous handler must come back on quit).
- Telemetry posture (any change at all to "no telemetry, ever" requires a logged decision and explicit user-facing disclosure).
- Visual treatment exceptions (anywhere we deliberately diverge from the 626Labs design system).

## References

- **Plan:** `~/.claude/plans/plan-mac-native-woolly-pascal.md`
- **Sibling repo (Windows):** `github.com/estevanhernandez-stack-ed/ROROROblox`
- **macRo (sibling 626 Labs Mac app):** `~/projects/macRo/` — release pipeline + design tokens template.
- **626Labs design system:** `~/.claude/skills/626labs-design/` (skill) + `~/projects/626labs-design/` (source).
- **The Architect persona + 626 Labs principles:** `~/.claude/CLAUDE.md`.
