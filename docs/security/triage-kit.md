# Triage kit

> **Pin this file.** When a security report lands, open this first. It's the only doc you need to touch in the first hour.

This is the front-of-house companion to [`disclosure-runbook.md`](disclosure-runbook.md). The runbook explains the *why* and the lifecycle; the kit is the *what to do right now* checklist.

---

## The first hour after a report arrives

The four things to do, in order. Aim to finish all four in under an hour. None of them are the fix — they're the setup.

### 1. Read the report. Don't write anything yet.

- Open the email (label `Security` in Gmail) OR the GitHub Security Advisory draft (Security tab → Advisories).
- Read it twice. Don't write a reply yet. Don't open the codebase yet.
- Decide which bucket it's headed for:
  - **In-scope vuln** → continue to step 2.
  - **Out-of-scope** (Roblox issue, design choice, SIP-disabled) → jump to *Out-of-scope routing* below.
  - **Quality bug masquerading as security** → jump to *Quality-bug routing* below.

### 2. Open a GitHub Security Advisory draft (if email-only)

If the report came via GitHub PVR, the advisory draft already exists. Skip this step.

If the report came via email:

```bash
gh api -X POST \
  -H 'Accept: application/vnd.github+json' \
  /repos/estevanhernandez-stack-ed/rororo-mac/security-advisories \
  -f summary='<one-line summary of the issue>' \
  -f description='<paste reporter content + attribution; mark "DRAFT — not for publication">' \
  -f severity=unknown \
  --silent
```

…or use the web UI: Repo → Security → Advisories → New draft security advisory.

The draft IS your private workspace from here forward. Everything stays inside the advisory until you publish.

### 3. Send the acknowledgement

Open [`templates/acknowledgement.md`](templates/acknowledgement.md). Copy the body. Fill `{REPORT_DATE}` and `{TRIAGE_DEADLINE}` (= report date + 14 days). Send via reply-all (email) or comment on the advisory draft (PVR).

Two minutes; don't overthink. The point is the reporter knows you're alive.

### 4. Set three calendar reminders

Copy from the *Calendar templates* section below. All three events go in *now*, not later — the day-80 reminder is the one that prevents the embargo from blowing past day 90 by accident.

---

## Calendar templates

Copy-paste into Apple Calendar, Google Calendar, or whatever lives next to your daily flow. Replace `{REPORT_DATE}` and `{REPORT_REF}` (the advisory ID or a short slug).

### Event 1 — Triage deadline

```
Title:        🔒 {REPORT_REF} — Triage by today
Date:         {REPORT_DATE} + 14 days
All day:      no
Time:         09:00, blocks 2 hours
Alarm:        2 hours before + 30 min before
Description:
  Security report {REPORT_REF} triage deadline.
  
  • Reproduce or refute.
  • Score severity per docs/security/severity-rubric.md.
  • Send the severity-assessment reply (docs/security/templates/severity-assessment.md).
  
  Advisory draft: <paste the GHSA-xxxx URL>
  Reporter contact: <email or GitHub handle>
```

### Event 2 — Soft warning

```
Title:        🟡 {REPORT_REF} — Fix progress check
Date:         {REPORT_DATE} + 60 days
All day:      yes
Alarm:        morning
Description:
  Security report {REPORT_REF} — soft fix-progress check.
  
  • Is the fix on a private branch?
  • Has the reporter validated it?
  • If not on track for day-90 ship, surface this NOW. Day 80 is too late to pull a release in.
  
  Advisory draft: <paste the GHSA-xxxx URL>
```

### Event 3 — Hard decision

```
Title:        🚨 {REPORT_REF} — Day 80 — extend or ship
Date:         {REPORT_DATE} + 80 days
All day:      no
Time:         09:00, blocks 1 hour
Alarm:        24 hours before + morning
Description:
  Security report {REPORT_REF} day-80 decision point.
  
  Pick ONE today:
    A) Fix is merged and through a release rehearsal → ship within the next 10 days. Set
       a follow-on event for ship day.
    B) Fix isn't ready → email the reporter THIS WEEK to negotiate an extension in writing.
       Don't let the deadline pass without their explicit consent.
  
  Silence = reporter free to publish on day 91. They warned us. SECURITY.md
  promised this.
  
  Advisory draft: <paste the GHSA-xxxx URL>
```

---

## Quick-routing — what kind of report is this?

A 30-second triage of the report category. Pick the closest match.

| The report says | This is a | Next move |
| --- | --- | --- |
| "I can steal the Roblox session cookie by…" | **Critical-class vuln, probably** | Acknowledge → use the severity-assessment template's *accepted finding* variant. Score per rubric. Get fix on a private branch within a week. |
| "The Sparkle signing key / Developer ID cert / notary creds are exposed in…" | **Critical** | Same flow, but also rotate the affected credential **immediately** — don't wait for the fix. The exposure is the incident. |
| "I can sign an update Sparkle will accept" | **Critical, possibly key-compromise** | Treat as the *Scenario B — COMPROMISED* path from the threat model's Sparkle playbook. Triage with assumption-of-breach. |
| "Roblox's login page can be impersonated / I can MITM the WKWebView" | **Probably out of scope** (Roblox infra / Apple ATS) | Use the severity-assessment *disputed / out-of-scope* variant. Point at Roblox or Apple. |
| "Auto-keys can post events to a non-Roblox window because of a focus race" | **High** | Already on the known-bug list. Acknowledge + score as High + tie into the existing fix work. Credit the reporter on the eventual fix advisory. |
| "URLSchemeHandler can be hijacked mid-session" | **High** | Already on the v0.1.0 ship list. Acknowledge + use the existing fix as the response timeline. Credit the reporter. |
| "Macro JSON can be tampered with on disk to inject keystrokes" | **Probably accepted-risk** | Check whether the report escalates *past* the macro JSON trust boundary. If yes → Medium. If no → out-of-scope using the *Accepted in threat model* line from the disputed template. |
| "RORORO can be removed by deleting the .app" / "users can disable the app" | **Out of scope** — explicit non-finding | Use the disputed template, cite SECURITY.md *"What we won't accept as findings"*. |
| "RORORO works on a SIP-disabled Mac in a way that…" | **Out of scope** — requires modified macOS config | Use the disputed template, cite the same section. |
| "Your privacy policy / cookie storage / Keychain ACL is wrong because…" | **Maybe in-scope, depends** | Read carefully. If it identifies a real leak surface → in-scope, score per rubric. If it's a hardening suggestion → Low. |
| "Here's a CVE I found by running a scanner against your deps" | **Probably Low or noise** | Look at the actual exploitability against RORORO. Most dep scanners surface CVEs in transitive code that RORORO doesn't reach. Polite reply, ask for an exploit path. |

When in doubt, escalate the bucket and document the reasoning. Under-scoring is harder to walk back than over-scoring.

---

## Out-of-scope routing

If the first read tells you it's out of scope, the response is still due in 7 days. Don't ghost the reporter — that's how policy reputations die.

1. Send the *disputed / out-of-scope* variant from [`templates/severity-assessment.md`](templates/severity-assessment.md).
2. Don't open a GitHub Security Advisory draft. The advisory format is for in-scope findings.
3. If the reporter pushes back, listen. Sometimes "this looks out-of-scope" turns into "actually there's an angle I didn't see." Re-open if so.
4. If the reporter doesn't push back, no further action — the thread closes on receipt.

---

## Quality-bug routing

Some reports are real bugs that aren't security issues. Don't bury them.

1. Reply with the disputed template, but offer to **convert the report into a public GitHub issue** with the reporter's permission. Credit them on the issue.
2. If the reporter agrees, open the public issue with their attribution. Close the security thread.
3. If they decline (some reporters won't accept that distinction), let it close politely.

---

## What's where (link index)

For when the kit doesn't cover your specific question:

- [`SECURITY.md`](../../SECURITY.md) — public-facing policy.
- [`disclosure-runbook.md`](disclosure-runbook.md) — the full operational doc.
- [`severity-rubric.md`](severity-rubric.md) — Critical / High / Medium / Low buckets + examples + fix windows.
- [`templates/acknowledgement.md`](templates/acknowledgement.md) — Day 0-7 reply.
- [`templates/severity-assessment.md`](templates/severity-assessment.md) — Day 7-14 reply with severity + timeline.
- [`templates/disclosure-publication.md`](templates/disclosure-publication.md) — Release-day reply + advisory body skeleton.
- [`../generated/threat-model.md`](../generated/threat-model.md) — STRIDE-shaped threat model.
- [`../security-audit.md`](../security-audit.md) — posture statement.
- [GitHub Advisories](https://github.com/estevanhernandez-stack-ed/rororo-mac/security/advisories) — repo's advisory list (draft + published).
- [Private Vulnerability Reporting form](https://github.com/estevanhernandez-stack-ed/rororo-mac/security/advisories/new) — the URL to give to researchers asking how to report.

---

## Setup confirmations

These are one-time setup tasks. Tick when done.

- [x] Gmail filter on estevan@626labs.dev for security-keyword matches with phone push notification. *(Confirmed 2026-05-11.)*
- [x] GitHub Private Vulnerability Reporting enabled. *(Confirmed 2026-05-11 via `gh api -X PUT /repos/.../private-vulnerability-reporting`.)*
- [x] GPG keypair generated for estevan@626labs.dev. Fingerprint inlined in `SECURITY.md`. *(Confirmed 2026-05-11. Fingerprint `E52F 4A54 4426 1AE7 0D12  D817 B928 75D4 F623 6B8A`.)*
- [x] Public key uploaded to keys.openpgp.org (email verification clicked). *(Confirmed 2026-05-11. Verified via `curl https://keys.openpgp.org/vks/v1/by-fingerprint/E52F4A5444261AE70D12D817B92875D4F6236B8A` — UID present, email-verified.)*
- [x] Public key added to GitHub. *(Confirmed 2026-05-11. Verified via `gh api /user/gpg_keys` — key id `B92875D4F6236B8A`, email `estevan@626labs.dev` verified on the account. Discoverable at github.com/estevanhernandez-stack-ed.gpg.)*
- [ ] Private key backup exported to 1Password; export file deleted from disk.
- [ ] First-report dry-run with a fake report (optional but recommended) — walk through this kit end-to-end before a real one arrives.
