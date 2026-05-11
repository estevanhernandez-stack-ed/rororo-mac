# Security Policy

Thanks for taking the time to look. RORORO Mac handles user authentication cookies, claims a system-wide URL scheme, and injects keyboard / mouse events under explicit user grants — taking security reports seriously is part of the deal.

## Supported versions

The latest GitHub release is the only supported version. Older releases do not receive security updates; users on older versions should update via Sparkle auto-update or re-download from the [Releases page](https://github.com/estevanhernandez-stack-ed/rororo-mac/releases).

## Reporting a vulnerability

Two ways to report. Either works; both reach the maintainer privately.

**Preferred — GitHub Private Vulnerability Reporting:** [open a private advisory draft](https://github.com/estevanhernandez-stack-ed/rororo-mac/security/advisories/new). Reports stay private until you and the maintainer agree to publish. The conversation, code review, and CVE issuance all happen inside the advisory. Fastest path for researchers who want clean attribution and a CVE.

**Email:** estevan@626labs.dev. Use this if GitHub PVR doesn't fit your workflow (or if the GitHub account itself is part of the report).

Please include:

- A description of the issue and its impact.
- The minimum reproduction steps you've found.
- The version of RORORO Mac affected (Settings → About).
- The macOS version you reproduced it on.

If you'd prefer encrypted email, request a GPG public key in your initial message and one will be sent before you share specifics.

## Disclosure timeline

- **Acknowledgement:** within 7 days of receiving the report (best-effort; this is a single-maintainer project).
- **Triage + initial assessment:** within 14 days.
- **Private fix window:** up to 90 calendar days from the initial report.
- **Public disclosure:** at fix release, or at the 90-day mark — whichever comes first.

If 90 days elapse without a fix or an explicit mutually-agreed extension, you're free to disclose publicly. Tell us first so we can have a heads-up post ready.

## Scope

**In scope:**

- The RORORO Mac app (anything under `App/`).
- The release pipeline (`tools/release/`, `.github/workflows/`).
- The Sparkle auto-update channel (signing, appcast.xml integrity, key custody).
- The Keychain vault, URL-scheme handler, multi-instance break, auto-keys event injection, and diagnostics bundle.

**Out of scope:**

- Roblox Corporation's infrastructure, login flows, or API. Report those directly to Roblox.
- Anti-detection / evasion / injection / patching surfaces. RORORO does not ship any of those by design ([`CLAUDE.md` § Hard rules](CLAUDE.md)).
- Defending against the user attacking their own Mac. A user with admin can read their own Keychain by typing their password — that is correct behavior.
- Defending against nation-state adversaries. See [`docs/generated/threat-model.md` § Threat-actor prioritization](docs/generated/threat-model.md).

## Safe harbor

We won't pursue legal action against researchers who:

- Make a good-faith effort to comply with this policy.
- Report privately first and give us the window above to respond.
- Don't access, modify, or destroy data beyond what's needed to demonstrate the issue.
- Don't attempt to deny service or disrupt other users.

If you're unsure whether something falls under safe harbor, email first and ask.

## What we won't accept as findings

- "RORORO doesn't require a master password" — that's a documented design choice. The login Keychain's own protections are the trust root.
- "RORORO can be removed by deleting the .app" — yes, this is desktop software; it has no anti-removal logic.
- "RORORO's URL-scheme claim can be overridden by another app" — LaunchServices is last-write-wins by design. We restore the previous handler on quit. See the threat model.
- Reports based on running a SIP-disabled or otherwise modified macOS configuration, unless the issue would persist on default-config macOS.

## References

- [`docs/security-audit.md`](docs/security-audit.md) — posture statement.
- [`docs/generated/threat-model.md`](docs/generated/threat-model.md) — STRIDE-shaped threat model.
- [`docs/security/severity-rubric.md`](docs/security/severity-rubric.md) — severity buckets + fix windows applied to reports.
- [`docs/security/disclosure-runbook.md`](docs/security/disclosure-runbook.md) — maintainer-facing operational runbook for the policy on this page.
- [`docs/security/triage-kit.md`](docs/security/triage-kit.md) — first-hour checklist for when a report lands.
- [`docs/PRIVACY.md`](docs/PRIVACY.md) — what's stored, what's transmitted.
