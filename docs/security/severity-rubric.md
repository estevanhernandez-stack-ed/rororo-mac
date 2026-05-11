# Severity rubric

Four buckets, four fix windows. Pick the most-severe bucket a finding fits — when in doubt, escalate, not de-escalate.

This rubric is opinionated for **RORORO Mac specifically**. A keystroke-injection bug is more severe here than in a generic desktop app because the whole product depends on the user trusting that we don't post events into the wrong window. A cookie leak is the worst-case ceiling because the cookie *is* the account. Calibration matters more than absolute scoring.

---

## The buckets

### Critical — fix in 30 days, ship out-of-cycle if needed

The mitigation surface around a load-bearing security primitive is broken, OR an attacker can compromise an account / signing key / update channel without user interaction.

**Examples:**

- **Cookie leak without user interaction.** A `.ROBLOSECURITY` cookie escapes the Keychain to disk, log file, crash report, network, screen, or another process without the user doing anything wrong. Account compromise is silent.
- **Sparkle EdDSA private key exposed** in source / repo / release artifact / CI logs.
- **Apple Developer ID cert + notary creds exposed**.
- **Sparkle update channel accepts an unsigned or wrong-key-signed update** as a result of a bug in our code (not Sparkle itself).
- **URL-scheme handler accepts URLs from another untrusted process and treats them as our own.**
- **Remote code execution** triggered by visiting a webpage, opening a URL, or any non-interactive vector.
- **A bug in `SemaphoreBreaker` or `RobloxLauncher`** that posts events into a process other than the intended Roblox window in a way that isn't a focus race (focus races are High, not Critical — see below).
- **Keychain ACL bypass** — another process reading our items without triggering the user prompt.

**Action posture:** drop everything for triage in <24h. Ship the fix through the normal release pipeline within 30 days. If the fix needs an out-of-cycle release, that's correct. Communicate proactively with the reporter — they may have additional context that accelerates the fix.

---

### High — fix in 60 days, prioritize over feature work

Cookie compromise *with* user interaction OR a primitive adjacent to a load-bearing trust root (Sparkle pub-key, signing cert, EdDSA verification, hardened runtime) is weakened but not broken.

**Examples:**

- **Cookie leak with user interaction** — user clicks an attacker link / pastes a payload / installs a malicious config, and only then does the cookie escape. Same blast radius as Critical, but the user has to be tricked.
- **`URLSchemeHandler.isClaimed` not re-checked pre-launch.** Already on the v0.1.0 ship list. A separately-installed malicious app could claim the scheme mid-session and intercept the next launch URL.
- **Hardened Runtime regression** — Release-build configs ship without the runtime enforced.
- **Per-launch Roblox.app copy verification bypass** — already on the v0.1.0 ship list (codesign re-verify before copy).
- **Focus-race when posting keystrokes** that lands keys into a non-Roblox window with measurable frequency. (Known-bug carry-forward in the threat model.)
- **Diagnostics bundle leaks a session-class secret** — private-server code, auth-ticket, or anything that grants partial account access — even if it doesn't leak the cookie itself.
- **Sparkle appcast pinning weakened** — accepts a downgrade or accepts a stale signature past its validity window.
- **Cross-account WKWebView bleed** that allows session reuse across launches in a way that breaks the isolation contract. (Today's `.nonPersistent()` story is the mitigation; if it regresses, this is High.)

**Action posture:** triage in <72h. Schedule the fix into the next monthly release at the latest. Don't ship parallel feature work in the same release if the fix is still in code review — feature stuff can wait one cycle.

---

### Medium — fix in 90 days, ship in the next regular release

Info disclosure of non-cookie data, DoS that requires physical access or specific user state, or escalation that requires a privilege the user has already explicitly granted.

**Examples:**

- **`accounts.json` / `favorites.json` leak via the diagnostics bundle** in a way that bypasses the existing redaction logic. (Same data Roblox makes public, but our bundle is supposed to be share-safe.)
- **Auto-keys kill-key reliability regression** — gesture is missed under specific event loads, leaving a macro running. (Known-bug carry-forward in the threat model.)
- **Multi-instance break leaks a window's pid into a non-Roblox process** through a side channel.
- **Macro library JSON tampering** that escalates to keystroke injection into a non-Roblox window. (Macro JSON tampering itself is Accepted-risk in the threat model; the *escalation past the trust boundary* is what makes this Medium.)
- **`URLSchemeHandler` doesn't restore the previous handler on quit** in specific failure modes (Sparkle relaunch crash, OS reboot during shutdown). Surfaces as "user's other apps stop opening Roblox links until they reinstall."
- **Stale per-instance Roblox.app copies leaking disk** beyond what `cleanupStaleInstances()` catches.

**Action posture:** triage in 1 week. Schedule the fix into the next regular release (which lands on the maintainer's normal cadence). 90 days is the hard ceiling; most Mediums ship in 30-60.

---

### Low — fix when convenient, may bundle with feature releases

Quality bugs with security-adjacent flavor, hardening opportunities, or issues that are theoretical without a credible exploit path on default-config macOS.

**Examples:**

- **Cosmetic info disclosure** — the about screen shows a build path, a debug log surfaces a username, a window title contains internal state.
- **Theoretical timing attacks** without a demonstrated extraction. Constant-time comparison wins for free if the fix is small; we don't promise constant-time everywhere.
- **Hardening suggestions that don't change the threat model** — "you could pin the Sparkle public key in two places instead of one," "you could check `csrutil status` and warn if SIP is off." Welcome, not urgent.
- **Defense-in-depth requests** for things already enforced by construction — "add an `os_log` redaction filter even though no code path passes the cookie to `os_log`." Accepted-risk in the threat model means we're not promising to add the defensive layer.
- **Issues that require a SIP-disabled or otherwise modified macOS configuration** to reproduce, and don't persist on default-config macOS.

**Action posture:** acknowledge with the same 7-day window. Set the expectation that the fix lands when adjacent code is touched, with no firm timeline. Researchers who want a CVE for a Low finding generally aren't getting one — be polite and explicit.

---

## Edge calls

**A bug that's High in theory but unreachable in practice.** Score on theory. If a reporter shows that an unreachable path becomes reachable in some future config, the score was already correct.

**A bug that's Medium in severity but trivial to fix.** Fix it in the next release regardless of the rubric window. Severity scoring is about deadlines, not priorities — High urgency overrides Medium severity.

**A bug that's Critical in severity but the reporter requests a longer embargo.** Honor the reporter's request *up to* 90 days. If they want longer, that's a coordinated-disclosure conversation; document it in writing in the GitHub Security Advisory draft.

**Two bugs combined are Critical, but neither alone is.** Score the chain as Critical and credit the reporter for the chain.

**Researcher disputes the severity.** Listen. If they have a credible escalation path you missed, re-score. If they don't, explain the rubric calmly. Disagreement is healthy; defensiveness isn't.

---

## What this rubric is not

- **Not CVSS.** CVSS is a useful sanity-check but optimized for enterprise SaaS — it scores RORORO weirdly because the "network attack vector" axis doesn't map onto a local desktop app well. Use this rubric for fix-window calls; cite a CVSS score if a CVE is being issued (GitHub Advisories will auto-suggest one).
- **Not a contract.** Fix windows are the working commitment, not a hard SLA. Negotiate with the reporter when reality conflicts with the calendar — in writing, before the deadline, not after.
- **Not a way to dodge fixes.** "This is Low" should be a defensible position the reporter can disagree with, not a way to avoid work. If you find yourself rationalizing a downgrade, escalate instead.

---

## Calibration log

Append a line to this section each time the rubric is used in anger. Helps future-you stay calibrated.

| Date | Report ref | Initial score | Final score | Notes |
| ---  | ---        | ---           | ---         | ---   |
| _no entries yet — first report will seed this_ | | | | |
