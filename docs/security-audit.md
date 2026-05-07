# RORORO Mac — Security Audit

**Date:** 2026-05-07
**Scope:** RORORO Mac at the Phase 7 / pre-v0.1.0 cut.
**Auditor:** Self-audit by Estevan Hernandez (with Claude Opus 4.7 as a second pair of eyes).

This is the Mac-port equivalent of [`docs/security-audit-2026-05-04.md`](https://github.com/estevanhernandez-stack-ed/ROROROblox/blob/main/docs/security-audit-2026-05-04.md) on the Windows port. Same posture, different OS primitives.

## Threat model

| Threat | Mitigation |
|---|---|
| Cookie exfiltration via filesystem snooping | Cookies live only in the macOS login Keychain (`kSecAttrAccessibleWhenUnlocked` + `kSecAttrSynchronizable: false`). Never written to plaintext disk. |
| Cookie exfiltration via process inspection | Cookie is held in plaintext only in memory during a single *Launch As* operation. Not written to logs. |
| Cookie exfiltration via iCloud Drive / Time Machine sync | Keychain entries are explicitly non-syncable. Application Support directory contains no cookies. |
| Password capture via fake-login phishing | We never see the password. Login happens inside `WKWebView` pointed at the real `https://www.roblox.com/login`. |
| MITM on auth-ticket exchange | All Roblox API calls are HTTPS-only (App Transport Security default). The endpoint validates the cookie server-side; tampering doesn't help an attacker. |
| Compromised RORORO update channel | Sparkle appcast is EdDSA-signed. `SUPublicEDKey` is baked into the app bundle at build time. An attacker who controls the appcast feed but not the EdDSA private key cannot ship a malicious update. |
| Stale URL scheme handler after crash | `URLSchemeHandler.claim()` saves the previous handler's bundle ID to UserDefaults before claiming. `restore()` runs on `willTerminate`; if the app crashes, the next launch can re-restore. |
| Per-instance Roblox copies leaking disk space | `RobloxAppCopier.cleanupStaleInstances()` runs on every boot, removes copies older than 24h. |

## Stack-level review

### Cookie storage

- **Keychain item type:** `kSecClassGenericPassword`
- **Service:** `com.626labs.rororo-mac.account-cookie`
- **Account:** Roblox `userId` as String
- **Accessibility:** `kSecAttrAccessibleWhenUnlocked` — readable only while the user is actively logged in. Sleep / lock blocks access.
- **Sync:** `kSecAttrSynchronizable: false` — never roams to iCloud Keychain.

These are the strictest reasonable settings for a session credential. `kSecAttrAccessibleAfterFirstUnlock` would let the daemon access cookies between unlocks (which we don't need); `kSecAttrAccessibleWhenUnlocked` is tighter.

### Login WebView

- `WKWebViewConfiguration.websiteDataStore = .nonPersistent()` — cookies the WebView scrapes during login disappear when the sheet closes. The only persistence path is the explicit `KeychainStore.set(...)` we run after a successful login.
- We don't override the User-Agent — the default WKWebView UA lets Roblox's login flow render correctly. We're not impersonating.

### Network

All HTTPS, all to Roblox-owned or GitHub-owned endpoints. Full list in [`PRIVACY.md`](PRIVACY.md). No third-party SDKs, no analytics.

### Distribution

- Apple Developer ID signed + notarized (Hardened Runtime in Release; off in Debug).
- App Sandbox: OFF (blocks the URL scheme + `Process.run` paths the multi-instance coordinator needs). Tradeoff vs sandboxed apps documented in `tools/release/README.md`.
- Sparkle EdDSA signing. Private key in 1Password + GitHub Secrets only. Loss of the private key is a one-way break (existing clients refuse updates from a regenerated key).

### Code provenance

- POSIX `sem_unlink` is a public-source technique. No code copied from Insadem, iigordev, or Avaluate.
- All three reference projects use the same approach; we reimplement in Swift. SHA-256 hashes of any reference binaries we shipped for verification land in `PROVENANCE.txt`.

## Findings

### High-severity: none

### Medium-severity: none

### Low-severity / future work

- **Per-account WKWebView data-store isolation.** Today all accounts share the same `.nonPersistent()` store, wiped between sheets. Per-account profile isolation (via `WKWebsiteDataStore.identifier`) would give stronger guarantees that one account's session can't bleed into another's add-account flow. Deferred to v0.2.
- **No `NSAppleEventsUsageDescription` in Info.plist.** Currently not needed (we use LaunchServices, not Apple Events). If a future feature requires Apple Events automation, add the usage string + the entitlement at the same time.
- **Compat-config remote feed.** Windows port fetches `roblox-compat.json` from a Gist at startup so we can ship semaphore-name updates within hours. Mac port doesn't yet — manual update via Sparkle is the v0.1.0 plan. Reconsider after the first Roblox-side rename event.
- **No code-signing of the in-flight per-instance app copies.** When we copy `/Applications/Roblox.app` and flip `LSMultipleInstancesProhibited`, the copy's signature is invalidated. macOS Gatekeeper will allow execution because the user explicitly launches it via `NSWorkspace`, but the copy won't pass `codesign --verify`. This is intentional (Roblox's signature is theirs to maintain, not ours to re-stamp) and consistent with how Windows port's `cp -a` works.

## Re-audit triggers

Re-audit (and bump the date at the top of this file) when any of these land:
- Any change to where cookies are stored (Keychain attributes, JSON file, etc.).
- Any new network endpoint.
- Any change to the `sem_unlink` posture or the per-launch copy flow.
- Any addition of telemetry, crash reporting, or analytics.
- A Sparkle key rotation.
- A change in App Sandbox or Hardened Runtime posture.
- A Roblox-side change that motivates anti-detection or evasion logic (we don't ship it; the audit captures why).
