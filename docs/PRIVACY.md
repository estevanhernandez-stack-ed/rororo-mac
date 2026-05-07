# Privacy Policy — RORORO Mac

**Effective date:** *(set on the day of public release)*
**Version:** *(matches release version when published)*
**Publisher:** 626 Labs LLC
**Contact:** estevan.hernandez@gmail.com

---

## TL;DR

- **Your Roblox password is never seen by RORORO.** Login happens inside Roblox's own page, embedded in a `WKWebView` (Apple's WebKit-based browser frame).
- **Roblox session cookies live in your login Keychain**, tied to your macOS user account. They cannot be moved off the machine and decrypted; they never sync to iCloud.
- **No telemetry. No analytics. No third-party tracking.** RORORO makes network calls only to Roblox-owned endpoints (during launch and avatar fetching) and to GitHub Releases (for Sparkle auto-update checks).
- **No data leaves your Mac** except the Roblox-side calls described below — the same calls Roblox.com would make from your browser.
- **You can delete everything** by removing the app from `/Applications`, deleting `~/Library/Application Support/RORORO/`, and removing the `com.626labs.rororo-mac.account-cookie` entries from Keychain Access.

---

## What RORORO stores on your Mac

| Location | Contents | Encryption / sensitivity |
|---|---|---|
| `~/Library/Application Support/RORORO/accounts.json` | Saved-account public profile data: Roblox userId, username, displayName, avatar URL, last-launched timestamp. | Plain JSON — no secrets |
| Login Keychain — service `com.626labs.rororo-mac.account-cookie`, account = Roblox userId | `.ROBLOSECURITY` session cookies. One Keychain item per saved account. | Encrypted by macOS Keychain. `kSecAttrAccessibleWhenUnlocked` (readable only when the user is logged in) + `kSecAttrSynchronizable: false` (never iCloud) |
| `~/Library/Application Support/RORORO/instances/<uuid>.app/` | Per-launch copies of `/Applications/Roblox.app`. Each copy gets `LSMultipleInstancesProhibited` flipped to `false` so it can run alongside other instances. | Public app bundles only — no private data |
| `~/Library/Preferences/com.626labs.rororo-mac.plist` | UI preferences (multi-instance toggle, default game URL) + saved URL-scheme handler bundle ID for restore-on-quit. | Plain plist — no secrets |
| `WKWebsiteDataStore` (in-memory only) | The login `WKWebView`'s cookie store during *Add Account*. Backed by `.nonPersistent()`. | Disappears the moment the sheet closes — never lands on disk |

---

## What RORORO does NOT store

- Your Roblox password. RORORO never receives it; it travels directly from your keystrokes inside the embedded login page to Roblox's servers via HTTPS.
- Personally identifiable information beyond what Roblox itself exposes via your saved session (display name, account ID, avatar URL — all public on Roblox).
- Any data on Apple, Anthropic, or 626 Labs servers. There is no backend; RORORO runs entirely on your Mac.
- Logs containing cookie values. Cookies are **never** logged — only redacted indicators when an error occurs.

---

## Network connections RORORO makes

RORORO initiates HTTPS connections **only** to:

| Host | When | Purpose |
|---|---|---|
| `auth.roblox.com` | During *Launch As* | Roblox's documented authentication-ticket endpoint — exchanges the saved cookie for a one-time launch ticket. The same endpoint Bloxstrap and other launchers use. |
| `users.roblox.com` | When adding an account | Public account metadata (display name, ID). Used to confirm the captured cookie maps to a real account. |
| `thumbnails.roblox.com` | When adding an account | Public avatar imagery. Best-effort — failures don't block account creation. |
| `626labs.github.io/rororo-mac/appcast.xml` | At app startup (when auto-checks are enabled) | Sparkle auto-update appcast — XML index of available releases, signed with EdDSA. |
| `github.com/estevanhernandez-stack-ed/rororo-mac/releases/...` | When applying an update | Sparkle downloads the update DMG from GitHub Releases. |

RORORO sends a `User-Agent` header of `RORORO-Mac/<version>` on every Roblox-side request. We do **not** spoof a browser UA. We are transparent and identifiable to the receiving servers.

RORORO makes **no other network connections**. There are no analytics endpoints, telemetry endpoints, or third-party SDKs.

---

## Account cookies and the macOS Keychain

When you click *Add Account*, RORORO opens an embedded `WKWebView` pointed at `https://www.roblox.com/login`. The login page is Roblox's own — same HTML, same form, same HTTPS connection your browser would make. Your keystrokes go from the embedded browser straight to Roblox's servers. RORORO is the window frame, not the form handler.

After Roblox confirms a successful login, RORORO captures the `.ROBLOSECURITY` session cookie that Roblox sets in the WebView's private cookie store. Before writing it anywhere else, RORORO calls `SecItemAdd` against your login Keychain — encryption tied to your specific macOS user account on your specific machine. The Keychain item is unreadable on any other Mac, by any other macOS user, and won't roam to iCloud (`kSecAttrSynchronizable: false`).

The cookie value is held in plaintext only briefly in memory during a single *Launch As* operation, then is read back from Keychain and handed to Roblox's auth-ticket endpoint. The cookie value is **never** written to logs, **never** included in error reports, and **never** transmitted to any party other than Roblox.

The `WKWebView`'s data store is `.nonPersistent()` — when the *Add Account* sheet closes, the cookie store evaporates. The cookie only persists where we explicitly put it: in Keychain.

---

## Children's privacy

RORORO is a launcher for the Roblox platform. We do not collect data from anyone, including children. Children should follow the privacy practices of Roblox itself when using the Roblox platform. RORORO launches the official Roblox client unmodified; we do not interpose between the user and Roblox's privacy-relevant flows.

---

## Trademark notice

"Roblox" and the Roblox logo are trademarks of Roblox Corporation. RORORO is an independent third-party tool, **not affiliated with, endorsed by, or sponsored by Roblox Corporation**. The trademarked term is used solely to describe compatibility with the Roblox platform.

---

## Changes to this policy

If we update this policy, we'll change the **Effective date** at the top and bump the **Version** to match. Material changes (e.g., adding a new network endpoint, adding any kind of data collection) will be called out in the release notes for the version that introduces them.

---

## Contact

Questions, concerns, or rights requests: [estevan.hernandez@gmail.com](mailto:estevan.hernandez@gmail.com)

Source code is open: [github.com/estevanhernandez-stack-ed/rororo-mac](https://github.com/estevanhernandez-stack-ed/rororo-mac)
