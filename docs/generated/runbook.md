# RORORO Mac — Runbook

> This is the maintainer's runbook for the **packaged macOS client**. RORORO Mac is a signed-and-notarized Swift / SwiftUI desktop app distributed via GitHub Releases + Sparkle 2.x. There is no server, no backend, no telemetry — so this is not a server runbook. The operational concerns are: what breaks on a user's Mac, how to detect it, how to mitigate it without shipping a new release, and how to ship a new release when one is required.

<!-- Source: README.md, CLAUDE.md, docs/spec.md, docs/PRIVACY.md -->

---

## §1 Overview

RORORO Mac is a Mac-native multi-Roblox launcher: account vault + multi-instance coordinator. Three load-bearing native primitives:

- **Keychain** — stores `.ROBLOSECURITY` cookies under service `com.626labs.rororo-mac.account-cookie` (`KeychainStore.swift`).
- **POSIX `sem_unlink`** — defeats Roblox's single-instance check on the named semaphore `/RobloxPlayerUniq` (`SemaphoreBreaker.swift`).
- **URL-scheme handler** — claims `roblox-player://` so launch URLs route through the multi-instance recipe (`URLSchemeHandler.swift`).

Distribution: signed `.pkg` (Developer ID Application + Developer ID Installer) → notarized → attached to a GitHub Release → Sparkle 2.x reads `https://estevanhernandez-stack-ed.github.io/rororo-mac/appcast.xml`.

Deployment target: macOS 14.0 (Sonoma) and later. No App Sandbox (blocks the URL-scheme + `Process.run` paths).

<!-- Source: README.md, docs/spec.md §3, tools/release/README.md, App/RORORO/Domain/KeychainStore.swift, App/RORORO/Domain/SemaphoreBreaker.swift, App/RORORO/Domain/URLSchemeHandler.swift -->

---

## §2 Operator persona

There is no on-call rotation. The operators are:

- **The maintainer** (Estevan / 626 Labs) — owns the Sparkle private key, the Apple Developer ID certs, the notarization credentials, and the gh-pages branch. Cuts releases by tagging `v*`.
- **The end user** — runs RORORO on their own Mac. Can capture a diagnostics bundle, can re-add an expired account, can revoke and re-grant Accessibility / Input Monitoring permissions.

Bug intake is **GitHub Issues** on `github.com/estevanhernandez-stack-ed/rororo-mac`. No PagerDuty, no Slack channel, no SLA — see §3.

<!-- Source: tools/release/README.md, CLAUDE.md -->

---

## §3 User-facing reliability expectations

Free, open-source, MIT-licensed. **No contractual SLA.** Best-effort maintenance on the maintainer's schedule. The hard guarantees are posture-shaped, not uptime-shaped:

- **No telemetry, ever.** Anonymous GitHub Releases download counts only — that's the entire observability surface. Any addition requires a logged decision in the 626Labs Dashboard and a release-notes call-out.
- **No cookie ever lands on disk in plaintext.** Keychain is the only persistence sink for `.ROBLOSECURITY`.
- **No anti-detection logic.** `sem_unlink` is a public POSIX call; that's all we use.

<!-- Source: CLAUDE.md "Hard rules", README.md, docs/PRIVACY.md -->

---

## §4 Common operational tasks

### 4.1 Capture a diagnostics bundle

Settings → Diagnostics → **Save bundle…**. Off-main assembly (Process calls + `/usr/bin/zip`); the destination is a `.zip` the user picks.

Bundle contents (per `DiagnosticsBundle.swift:1-30`):

| File | What it carries |
| --- | --- |
| `diagnostics.txt` | RORORO version, Roblox install present (path), multi-instance enabled, launches this session, URL-scheme claim status, effective semaphore name, compat feed freshness, last error |
| `accounts.json` | Verbatim — no cookies (cookies live in Keychain). |
| `favorites.json` | Verbatim — no secrets. |
| `private-servers.json` | Per-server `code` field replaced with `<REDACTED>` before write (share-link tokens are session-class secrets). |
| `system-info.txt` | macOS version, hostname, locale, Roblox.app version (read from its `Info.plist`). |
| `recent-logs.txt` | `log show --predicate 'process == "RORORO"' --last 1h --style syslog`. |
| `url-scheme-handler.txt` | Current `roblox-player://` handler bundle ID + saved-previous handler (the one we'll restore on quit). |

The bundle is the standard ask for any user-reported issue. The `<REDACTED>` redaction is one-way — the user can't accidentally share a private-server code in a GitHub issue.

<!-- Source: App/RORORO/Domain/DiagnosticsBundle.swift -->

### 4.2 Re-login flow when a cookie expires

Symptom: user clicks **Launch As** and sees the banner *"This account's login expired. Remove and re-add."* This is `RobloxApi.APIError.cookieExpired` surfaced from the auth-ticket call (Roblox 401 → our error mapping; see `RobloxLauncher.swift:60-65` + `docs/spec.md §6`).

User flow:

1. Open RORORO, select the account, click **Remove**. Keychain entry deleted via `KeychainStore.delete(service:account:)`.
2. Click **+ Add Account**. The `CookieCapture` `WKWebView` opens `https://www.roblox.com/login` against a `.nonPersistent()` data store (`CookieCapture.swift:67`).
3. User completes Roblox's own login form — 2FA, captchas, social auth all handled by Roblox's page. RORORO never sees the password.
4. On successful login, `CookieCapture` reads `.ROBLOSECURITY` from the WebView cookie store, validates via `RobloxApi.getUserProfile`, and `AccountStore.add` writes the cookie to Keychain.

The WebView's data store is wiped when the sheet closes (`.nonPersistent()`). The cookie only persists where we explicitly put it: Keychain.

<!-- Source: App/RORORO/Domain/CookieCapture.swift, App/RORORO/Domain/RobloxLauncher.swift, docs/spec.md §6 -->

### 4.3 Cut a release

Bootstrap must already be complete — four secrets in GitHub Actions (`SPARKLE_ED_PRIVATE_KEY`, `MACOS_CERTIFICATE` + Installer, `APPLE_ID` / `APPLE_TEAM_ID` / `APPLE_NOTARY_PASSWORD`) plus gh-pages enabled. See `tools/release/README.md` "Bootstrap" for the one-time setup.

**Cutting a release is a single command from a human terminal**, never from Claude (`CLAUDE.md` hard rule: "Don't tag `v0.1.0` from Claude. That's a human-only step after the four bootstrap secrets are uploaded."):

```bash
git tag v0.1.0
git push origin v0.1.0
```

The `.github/workflows/release.yml` workflow then:

1. Archives Release config with manual signing (`xcodebuild archive`, `MARKETING_VERSION=<tag>`, `CURRENT_PROJECT_VERSION=<git rev-list --count HEAD>`).
2. `codesign --force --deep --timestamp --options runtime` over the bundle (re-signs Sparkle's nested helpers under our Developer ID).
3. Submits the `.app` zip to Apple's notary via `xcrun notarytool submit --wait`; staples on success.
4. `productbuild --component <app> /Applications --sign <Installer cert>` to a flat `.pkg`.
5. Submits the `.pkg` to notary; staples on success.
6. Attaches the `.pkg` to the GitHub Release; regenerates `dist/appcast.xml`; publishes `dist/` to `gh-pages`.

Verification (per `tools/release/README.md` "Cutting a release"):

- The Release page shows the notarized `.pkg` attached.
- `https://estevanhernandez-stack-ed.github.io/rororo-mac/appcast.xml` serves a new `<item>` with `sparkle:version` = `git rev-list --count <tag>` (monotonic build number — load-bearing for Sparkle's dotted-numeric compare).
- A pre-existing install prompts for the update on next launch.

<!-- Source: tools/release/README.md, tools/release/notarize.sh, tools/release/generate-appcast.sh, .github/workflows/release.yml, CLAUDE.md -->

### 4.4 Sparkle channel custody

The Sparkle EdDSA **private key** is the single most critical secret in the release pipeline. Loss is a **one-way break** — every existing client refuses updates from a regenerated key (per `tools/release/README.md` and `CLAUDE.md`).

Custody:

- **Authoritative copy:** 1Password vault, item `RORORO Mac / Sparkle Private Key`.
- **CI copy:** GitHub Actions secret `SPARKLE_ED_PRIVATE_KEY` on `estevanhernandez-stack-ed/rororo-mac`.
- **Local-machine copy:** macOS Keychain under service `https://sparkle-project.org`, generated by Sparkle's `generate_keys` utility.

Rotation procedure: documented in `tools/release/README.md` Bootstrap §1, but rotation is **not** routine — once shipped to a public release, the public key is baked into every client's `Info.plist` as `SUPublicEDKey`. A new keypair forks the client base.

Re-audit trigger per `docs/security-audit.md` "Re-audit triggers": any Sparkle key rotation.

<!-- Source: tools/release/README.md, CLAUDE.md, docs/security-audit.md -->

---

## §5 Failure modes

One section per known failure. Format: symptom → detection → mitigation → rollback → prevention.

### 5.1 Keychain access denied or vault drained

**Symptom.** User clicks **Launch As**, sees *"No cookie stored. Remove and re-add."* — or any account that previously worked now claims its cookie is missing.

**Detection.** `KeychainStore.get(service:account:)` returns `nil` for an account whose userId is still in `accounts.json`. `LauncherError.cookieMissing(userId:)` is raised by `RobloxLauncher.launch` at step 1 (cookie pull). Surfaces in the UI as a banner. The diagnostics bundle's `accounts.json` will list the account; the cookie absence won't show up directly (cookies never land in the bundle by design).

**Possible causes.**

- User restored from Time Machine or migrated Macs — Keychain items with `kSecAttrSynchronizable: false` don't roam to a new machine. By design (`KeychainStore.swift:11-14`); the cookie is a session credential tied to the local machine.
- User changed their macOS account password recently — Keychain access list may have invalidated the legacy-format entry; subsequent reads return `errSecAuthFailed`. `KeychainStore.get` throws `unexpectedStatus(status)`.
- User manually deleted `com.626labs.rororo-mac.account-cookie` entries via Keychain Access.
- macOS screen is locked and a background read attempted — `kSecAttrAccessibleWhenUnlocked` blocks access until the user unlocks (`KeychainStore.swift:65-66`).

**Mitigation.** Re-login flow (§4.2): remove the account from RORORO, then **+ Add Account** to re-capture the cookie.

**Rollback.** N/A — this is per-account state on the user's machine. No release-level rollback.

**Prevention.** None code-side; the privacy posture (non-syncable, non-iCloud) is intentional. Document the "fresh Mac → re-login required" expectation in user-facing docs.

<!-- Source: App/RORORO/Domain/KeychainStore.swift, App/RORORO/Domain/RobloxLauncher.swift, docs/spec.md §6 -->

### 5.2 `.ROBLOSECURITY` cookie expired

**Symptom.** **Launch As** banner: *"This account's login expired. Remove and re-add."*

**Detection.** `RobloxApi.APIError.cookieExpired` raised when `auth.roblox.com/v1/authentication-ticket` returns 401 (per `docs/spec.md §6`). Distinct from cookie-missing — the Keychain entry is intact; Roblox just rejected the cookie.

**Possible causes.**

- User logged out of Roblox in a browser (some flows invalidate the session globally).
- User changed their Roblox password elsewhere.
- Roblox-side session expiry (session cookies have a server-controlled lifetime).
- Suspicious-activity flag on Roblox's end forced a re-login.

**Mitigation.** Re-login flow (§4.2). Re-capture the cookie via **+ Add Account**.

**Rollback.** N/A.

**Prevention.** None — server-side expiry is outside our control. Surface clear copy in the error banner so the user knows what action to take.

<!-- Source: App/RORORO/Domain/RobloxApi.swift (referenced), docs/spec.md §6 -->

### 5.3 Multi-instance break regressed by a Roblox or macOS update

**Symptom.** With **Multi-Instance: ON**, the second **Launch As** activates the already-running first instance instead of spawning a new one. Tray ring may go magenta with an error.

**Detection.** `MultiInstanceState.shared.lastError` populated. Diagnostics bundle's `diagnostics.txt` reports `Effective semaphore: <name>` — if the value still says `/RobloxPlayerUniq` but the second launch coalesces, the semaphore name has likely been renamed in a Roblox update. `SemaphoreBreaker.swift:32-39` notes the silent-no-op risk: an unknown name returns `.alreadyUnlinked` rather than `.unlinked`, and launches start failing without an obvious errno.

**Mitigation (out-of-band, no app release).** The semaphore name is hot-patchable via the **compat config** feed at `https://estevanhernandez-stack-ed.github.io/rororo-mac/roblox-compat.json` (per `tools/release/generate-appcast.sh:30-35` + `tools/release/roblox-compat.json`). Steps:

1. Identify the new semaphore name (`sudo dtruss -t sem_open` on a fresh Roblox launch, or community report).
2. Edit `tools/release/roblox-compat.json` — bump `semaphoreName` to the new value, bump `version`, set `updatedAt`.
3. Push the updated file directly to the `gh-pages` branch (out-of-band — no new app tag needed). `RobloxCompatStore.shared.refresh()` runs at every `bootIfNeeded` and pulls the new value.

Users see the fix on their next app launch.

**Rollback.** Revert the `roblox-compat.json` commit on `gh-pages`. The in-app `RobloxCompatStore` falls back to the cached value, then to the hardcoded default `/RobloxPlayerUniq`.

**Prevention.** Smoke test multi-instance after every Roblox client update. Surface effective semaphore name in Diagnostics view so community reports include it.

**Re-audit trigger.** Any change to the `sem_unlink` posture or per-launch copy flow — `docs/security-audit.md` requires a re-audit.

<!-- Source: App/RORORO/Domain/SemaphoreBreaker.swift, App/RORORO/Domain/MultiInstanceCoordinator.swift, tools/release/roblox-compat.json, tools/release/generate-appcast.sh -->

### 5.4 URL-scheme handler not restored on quit

**Symptom.** User quits RORORO but `roblox-player://` URLs (Play buttons on roblox.com) still route through RORORO — or worse, route to nothing if RORORO was uninstalled while still claimed.

**Detection.** `URLSchemeHandler.shared.isClaimed` reports true post-quit (re-check via Finder *Get Info → Open with* on a `.roblox-player` URL or via `defaults read com.apple.LaunchServices`). Diagnostics bundle's `url-scheme-handler.txt` reports current handler bundle ID and saved-previous handler.

**Cause.** `URLSchemeHandler.restore` is fired async from `willTerminateNotification` (`MultiInstanceCoordinator.swift:220-232`). The app may exit before the `NSWorkspace.setDefaultApplication` completion handler runs. `UserDefaults` still holds the previous handler key (`RORORO.URLSchemeHandler.savedRobloxPlayerHandler`); on next boot, `bootIfNeeded` re-claims and the saved-previous entry remains available for the next quit's restore. If RORORO crashes hard mid-session, same recovery path.

**Mitigation (user).**

- Reopen RORORO once and quit cleanly — `URLSchemeHandler.restore` fires again and the saved-previous handler is reinstated.
- Or: Settings → **Reset system handler** button (`MultiInstanceCoordinator.shutDown()` calls `URLSchemeHandler.restore`).
- Or: manual macOS recourse — open Finder → right-click any saved `roblox-player://` link → *Get Info → Open with → /Applications/Roblox.app*.

**Rollback.** N/A — local state.

**Prevention.** The save-on-first-claim-only pattern (`URLSchemeHandler.swift:73-81`) avoids the worst footgun: re-saving on every claim could overwrite the original handler with RORORO's own bundle ID if a previous session crashed mid-launch. Code already guards against this.

<!-- Source: App/RORORO/Domain/URLSchemeHandler.swift, App/RORORO/Domain/MultiInstanceCoordinator.swift -->

### 5.5 Sparkle auto-update broken

**Symptom.** Users on older versions don't see an update prompt — *or* the prompt appears but installation fails with an EdDSA signature error.

**Detection (maintainer-side).**

- `https://estevanhernandez-stack-ed.github.io/rororo-mac/appcast.xml` returns a non-200 or stale XML.
- The latest GitHub Release shows a `.pkg` attached but no corresponding `<item>` in the appcast.
- `xcrun notarytool history` shows the release notarized cleanly but `sign_update`'s output is empty or mis-signed.
- User-side: Help → Check for Updates shows "You're up to date" against a known-newer release (this is the v0.2.2 footgun caught at smoke 2026-05-07 — Sparkle's dotted-numeric compare treated `CFBundleVersion="2"` as newer than `0.2.x`; the fix is monotonic build numbers from `git rev-list --count HEAD`, baked into both the bundle at archive time and the appcast's `sparkle:version`).

**Mitigation.**

- **Appcast unreachable / 404:** GitHub Pages status; check the `gh-pages` branch has the latest `dist/appcast.xml`. Re-run the Release workflow on a no-op commit if the deploy job failed silently.
- **EdDSA signature mismatch:** `SPARKLE_ED_PRIVATE_KEY` in GitHub Secrets diverged from the public key baked into shipped clients' `Info.plist`. **Do not rotate the key** — this is the one-way break (§4.4). Restore the authoritative private key from 1Password into the GitHub secret.
- **Version-compare regression:** confirm `sparkle:version` in the appcast `<item>` is the monotonic build number (`git rev-list --count <tag>`), not the marketing string. `tools/release/generate-appcast.sh:138-144` computes this; if missing, the script warns and skips the tag.

**Rollback (Sparkle channel rollback).** Per `tools/release/README.md` "Rolling back a broken release":

- **Mark the release as pre-release** in the GitHub Release UI. Sparkle clients on the stable channel skip pre-release items (`generate-appcast.sh:198-200` emits `<sparkle:channel>prerelease</sparkle:channel>` for pre-release items). The bad update stops surfacing.
- **Do NOT delete the release.** Sparkle clients may have cached the asset URL; a 404 is a worse failure mode than a visible pre-release flag.
- Publish a hotfix `v0.x.y+1` to fan out the actual fix to the stable channel.

**Prevention.** Local dry-run before tagging: export the env vars per `tools/release/README.md` "Local-only notarize" and run `notarize.sh` + `generate-appcast.sh` manually. Smoke-test the appcast against a pre-existing install.

<!-- Source: tools/release/README.md, tools/release/generate-appcast.sh, tools/release/notarize.sh, App/RORORO/Domain/UpdaterHost.swift -->

### 5.6 Accessibility permission revoked — auto-keys breaks

**Symptom.** Auto-keys macro cycler doesn't post keystrokes — clicks Start, nothing happens. Or: macro recorder doesn't capture the user's keypresses.

**Detection.** `AutoKeysPermissions.accessibilityStatus()` returns `.denied` (Accessibility — `AXIsProcessTrusted()`). `AutoKeysPermissions.inputMonitoringStatus()` returns `.denied` or `.notDetermined` (Input Monitoring — `IOHIDCheckAccess(.listenEvent)`). The two surfaces are separate panes in macOS 14+ System Settings.

**Cause.** User revoked Accessibility or Input Monitoring in *System Settings → Privacy & Security*; or a macOS update bumped the TCC database in a way that drops permissions for unsigned/dev-signed builds; or the user has the toggle on for a different RORORO binary path (re-signing via local rebuild creates a new TCC identity).

**Mitigation.** From the auto-keys UI, deep-link to each pane:

- **Accessibility:** `AutoKeysPermissions.openAccessibilitySettings()` — fires the native prompt + opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` (`AutoKeysPermissions.swift:70-76`).
- **Input Monitoring:** `AutoKeysPermissions.openInputMonitoringSettings()` — fires the native prompt + opens `Privacy_ListenEvent` (`AutoKeysPermissions.swift:82-87`).

User toggles RORORO on in each pane and returns. No restart needed.

**Rollback.** N/A — TCC consent is per-user/per-binary; no release rollback.

**Prevention.** Ship only signed builds to end users (TCC consent survives across versions when the code signature identity is stable). For dev rebuilds, expect to re-grant after every signing-identity change.

<!-- Source: App/RORORO/Domain/AutoKeys/AutoKeysPermissions.swift -->

### 5.7 Roblox.app bundle path moved or missing

**Symptom.** **Launch As** banner: *"Roblox is not installed at /Applications/Roblox.app."* Or: launches go through but FFlag injection silently fails.

**Detection.** `RobloxAppCopier.CopyError.sourceMissing` raised from `RobloxAppCopier.copyAppForInstance` (per `docs/spec.md §6`). Diagnostics bundle's `diagnostics.txt` line: `Roblox installed: No at /Applications/Roblox.app`. FFlag-write failures land via `RobloxBundleResolver.resolveBundle()` returning `nil` (`RobloxBundleResolver.swift:34-44`).

**Resolution order** (per `RobloxBundleResolver.swift:34-44`):

1. Spotlight `mdfind kMDItemCFBundleIdentifier == 'com.roblox.RobloxPlayer'` with a 1.5s timeout (most-recently-modified wins on multi-install).
2. `/Applications/Roblox.app`.
3. `~/Applications/Roblox.app`.

Each candidate's `Info.plist` must report `CFBundleIdentifier` starting with `com.roblox`.

**Mitigation.**

- **Installed elsewhere:** Spotlight should catch it. If Spotlight is disabled on the user's machine, advise them to move Roblox to `/Applications/Roblox.app` (the canonical location).
- **Not installed at all:** user installs Roblox from `https://www.roblox.com/download`. No RORORO-side workaround; we're a launcher, not a downloader.
- **Spotlight indexing stale:** `mdimport /Applications/Roblox.app` rebuilds the index for the canonical path.

**Rollback.** N/A.

**Prevention.** Validate bundle presence at `bootIfNeeded` and surface to diagnostics. Already done in `DiagnosticsBundle.buildTextDump` (`Roblox installed: ...`).

<!-- Source: App/RORORO/Domain/RobloxBundleResolver.swift, App/RORORO/Domain/DiagnosticsBundle.swift, docs/spec.md §6 -->

### 5.8 DMG / PKG fails Gatekeeper on first launch

**Symptom.** User double-clicks `RORORO.pkg`; macOS Installer reports *"RORORO can't be opened because Apple cannot check it for malicious software"* or *"The installer package is damaged."*

**Detection.** Common causes:

- **Notary submission rejected** during the release workflow. `notarize.sh:130-140` exits with `::error::Notarization status is '...'` and the workflow run fails — the broken `.pkg` never gets attached to the Release. If it did get attached (e.g. a hand-rolled local build was uploaded), `spctl --assess --type install <pkg>` will reject it.
- **Stapling failed.** `xcrun stapler validate` exits non-zero. Sometimes the network-side ticket fetch races; re-stapling resolves.
- **Cert expired.** Developer ID Application or Developer ID Installer cert past expiry. `security find-certificate -c "Developer ID Application: Estevan Hernandez"` shows the validity window.

**Mitigation.**

- **Workflow failed in CI:** read the notary log (`notarize.sh:132-138` auto-fetches via `xcrun notarytool log $SUBMISSION_ID`). Common reasons: a binary in the bundle missing Hardened Runtime, or a Sparkle helper signed by the Sparkle Project's cert instead of ours. The `--deep --timestamp --options runtime` re-sign step (`notarize.sh:107-108`) handles the latter.
- **Cert expired:** generate new certs at `developer.apple.com/account/resources/certificates`, re-upload to GitHub Secrets (`MACOS_CERTIFICATE`, `MACOS_INSTALLER_CERTIFICATE`, plus the `_NAME` and `_PASSWORD` companions). Re-run the Release workflow.
- **Local-build user:** advise them to download the signed `.pkg` from GitHub Releases instead.

**Rollback.** Mark the broken release as pre-release (§5.5). Ship a hotfix.

**Prevention.** `notarize.sh` already fails fast on bad notary status and fetches the log. The bootstrap doc (`tools/release/README.md`) calls out the two-cert (Application + Installer) requirement explicitly — distinct certs, both needed.

<!-- Source: tools/release/notarize.sh, tools/release/README.md -->

---

## §6 Alerting / paging

`NOT APPLICABLE — open-source desktop app, no telemetry, no alerting.` See §3.

---

## §7 Scaling / capacity

`NOT APPLICABLE — runs on the user's Mac.` Multi-instance is bounded by user disk space (per-launch ~600 MB Roblox.app copy under `~/Library/Application Support/RORORO/instances/`) and the user's CPU/GPU. `RobloxAppCopier.cleanupStaleInstances()` runs on every boot and removes copies older than 24h (per `docs/security-audit.md` threat-model row).

<!-- Source: docs/security-audit.md, App/RORORO/Domain/MultiInstanceCoordinator.swift:87-93 -->

---

## §8 Diagnostics

### 8.1 In-app

- Settings → Diagnostics → **Save bundle…** — see §4.1.
- Settings → Diagnostics → **Copy** — same structured text dump, clipboard-bound for fast paste into a GitHub issue.
- Tray ring color: cyan = multi-instance ON + clean, slate = OFF, magenta = `MultiInstanceState.shared.lastError` populated.

### 8.2 macOS-side

- `log show --predicate 'process == "RORORO"' --last 1h --style syslog` — the same call `DiagnosticsBundle.fetchRecentLogs` makes.
- Console.app filtered to process `RORORO` — live tail.
- Activity Monitor — confirm spawned Roblox instances are listed as distinct PIDs (multi-instance working).
- `ls -la ~/Library/Application\ Support/RORORO/instances/` — per-launch copies; stale entries older than 24h should be auto-removed on next app boot.

### 8.3 Sparkle-side

- `defaults read com.626labs.rororo-mac SUFeedURL` — confirm the appcast URL is the production one.
- `defaults read com.626labs.rororo-mac SULastCheckTime` — when Sparkle last checked.
- `curl -I https://estevanhernandez-stack-ed.github.io/rororo-mac/appcast.xml` — appcast reachability + `Last-Modified`.

<!-- Source: App/RORORO/Domain/DiagnosticsBundle.swift, README.md, docs/spec.md §3 -->

---

## §9 Escalation

There is no escalation tree — this is a one-maintainer open-source project. The intake path is:

1. **User-reported issue** → GitHub Issue on `estevanhernandez-stack-ed/rororo-mac`. Maintainer triages.
2. **Privacy / security concern** → email `estevan.hernandez@gmail.com` (per `docs/PRIVACY.md` contact) so it doesn't sit in a public issue thread.
3. **Sparkle key compromise suspected** → immediate manual rotation per §4.4 (one-way break — last resort).

<!-- Source: docs/PRIVACY.md, README.md -->

---

## §10 Re-audit triggers

Per `docs/security-audit.md` — bump the audit date and re-run when any of these land:

- Any change to where cookies are stored (Keychain attributes, JSON file, etc.).
- Any new network endpoint.
- Any change to the `sem_unlink` posture or per-launch copy flow.
- Any addition of telemetry, crash reporting, or analytics.
- A Sparkle key rotation.
- A change in App Sandbox or Hardened Runtime posture.
- A Roblox-side change that motivates anti-detection or evasion logic (we don't ship it; the audit captures why).

<!-- Source: docs/security-audit.md -->

---

## §11 Operational policies

### §11.1 Support posture

No SLA. Best-effort triage on the maintainer's schedule. Open-source MIT app, free to use — bug reports are GitHub Issues, fixes land when a release cycle warrants one. Users should size expectations accordingly: a working day's turnaround is plausible; a calendar week's worst case; multi-week silences are possible and not abandonment.

<!-- Source: maintainer decision 2026-05-11. No contractual commitment given the project's open-source, single-maintainer posture. -->

### §11.2 Bus factor

Currently 1. The Sparkle EdDSA private key, the Apple Developer ID certificates, the notarization credentials, and gh-pages push access for the compat-config feed all sit with the single maintainer (Estevan / 626 Labs). If the maintainer becomes unavailable, the project goes dormant — no new releases, no compat-feed updates for `sem_unlink` regressions, no new Sparkle-signed updates.

This is the explicit accepted posture, not a hidden risk. Users running RORORO Mac should treat it as a single-maintainer side-project. A second-key custodian / handoff plan would close the gap; revisit if the project's user base grows enough to justify it.

<!-- Source: maintainer decision 2026-05-11. CLAUDE.md warns "Sparkle EdDSA private key — losing the private key forces every existing client off the update channel" — that's the one-way break that defines the bus-factor scope. -->

### §11.3 Identifying a renamed Roblox singleton semaphore

When multi-instance launches stop working — symptom: only one Roblox window comes up no matter how many accounts you launch — the most likely cause is that Roblox renamed the named POSIX semaphore that gates singleton enforcement. `SemaphoreBreaker.swift` calls `sem_unlink("/RobloxPlayerUniq")`; if Roblox renames it, `sem_unlink` returns `ENOENT` and we silently report `.alreadyUnlinked` (see `SemaphoreBreaker.swift:35-39`). The user's diagnostics bundle shows `effective semaphore name: /RobloxPlayerUniq` but multi-instance still fails — that's the tell.

**Canonical detection (no sudo, no SIP changes, no runtime attach):**

```bash
# The semaphore name is a plain string literal in the RobloxPlayer Mach-O binary.
# Empirically verified 2026-05-11 against Roblox 0.720.0.7201168.

strings /Applications/Roblox.app/Contents/MacOS/RobloxPlayer \
  | grep -E '^/[A-Z][A-Za-z]+Uniq$|^/RobloxPlayer[A-Za-z]*$'

# Expected hit set as of v0.720:
#   /robloxPlayerStartedEvent     <- Mach kernel event, not our target
#   /RobloxPlayerUniq             <- THIS is the singleton semaphore name

# Update App/RORORO/Domain/RobloxCompatConfig.swift to the new value,
# rebuild, and verify multi-instance works again on a clean run.
```

This works on every modern macOS, runs in milliseconds, doesn't need Roblox to be running, and doesn't need sudo. The literal is embedded by Roblox's build — they'd have to actively obfuscate string literals (they don't today) to break this recipe.

**Why not `dtruss` / `dtrace`:** requires SIP off (`csrutil disable` from Recovery). Most maintainers don't keep a SIP-disabled dev mac.

**Why not `fs_usage`:** POSIX named semaphores on macOS are kernel-only; they don't traverse VFS. `fs_usage` produces no semaphore events. Confirmed empirically 2026-05-11 — `/private/var/run/usem*`, `/private/tmp/usem*`, and `/dev/shm` are all absent, and `lsof` on a running RobloxPlayer shows zero semaphore file descriptors.

**Why not `lldb -p` attach:** without sudo, `task_for_pid` is denied for hardened-runtime signed apps (`error: attach failed: Not allowed to attach to process`). With sudo it would work, but the `strings` recipe above is simpler and doesn't require Roblox to be running.

**Fallback if strings-grep ever fails** (Roblox starts obfuscating the literal):

```bash
# sudo lldb attach — works on default macOS (SIP on) with maintainer password.
# Launch ONE Roblox.app fresh first, get its pid, then:

sudo lldb -p $(pgrep -x RobloxPlayer | head -1)
(lldb) breakpoint set --name sem_open
(lldb) breakpoint set --name sem_unlink
(lldb) continue
# At each hit (arm64): register read x0; then memory read --format s --count 1 <addr>
# At each hit (x86_64): register read rdi; then memory read --format s --count 1 <addr>
# The string at that address is the semaphore name.
```

<!-- Source: empirically tested 2026-05-11 against /Applications/Roblox.app/Contents/MacOS/RobloxPlayer (Roblox 0.720.0.7201168). strings + grep returned /RobloxPlayerUniq directly. fs_usage / lsof confirmed POSIX semaphores are not file-backed on macOS. lldb -p without sudo confirmed denied by task_for_pid; with sudo expected to work (not run end-to-end during the test to avoid prompting for password). -->
