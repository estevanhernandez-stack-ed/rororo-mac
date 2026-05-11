# Disclosure runbook

Maintainer-facing operational doc for the [`SECURITY.md`](../../SECURITY.md) 90-day private disclosure window. This is what to do when a vulnerability report lands.

## The four commitments

The 90-day window in `SECURITY.md` boils down to four obligations to the reporter:

1. **Be reachable.** estevan@626labs.dev + GitHub Security Advisories.
2. **Acknowledge within 7 days.** Just a "got it, triaging" — not a fix.
3. **Triage within 14 days.** Severity + scope + timeline.
4. **Ship a fix before day 90.** Or negotiate an extension with the reporter; never let it lapse silently.

That's the entire commitment. Everything below is making those four things easier when a report arrives.

---

## Detection — make sure reports actually reach you

### Email path (estevan@626labs.dev)

Set up a Gmail filter the day you ship `SECURITY.md`. Any of these should trip a label + push notification on the phone:

- Body contains any of: `vulnerability`, `security`, `CVE`, `exploit`, `disclosure`, `responsible disclosure`, `vuln`
- Subject contains any of: `[SECURITY]`, `[CVE]`, `vuln`, `exploit`
- From-domain is on an allowlist of common security-research domains (HackerOne, Bugcrowd, etc.) — optional but useful

The phone notification is the load-bearing part. A silent inbox is the single most common cause of "the project promised 7 days and took 6 weeks."

### GitHub path (Private Vulnerability Reporting)

When PVR is enabled on the repo, reports come in as **private GitHub Security Advisory drafts**. They land in the repo's Security tab + email a notification to the repo admin (you).

Enable once: `gh api -X PATCH /repos/estevanhernandez-stack-ed/rororo-mac/private-vulnerability-reporting -H 'Accept: application/vnd.github+json' --silent` — or repo Settings → Code security and analysis → Private vulnerability reporting → Enable.

PVR is the preferred channel for researchers because it auto-handles the embargo: the conversation is private until you publish.

---

## The lifecycle of a report

```
Day 0      Report arrives (email or GitHub Security Advisory)
           → Read it. Don't write anything yet.

Day 0-7    Acknowledgement
           → Send the acknowledgement template (docs/security/templates/acknowledgement.md)
           → Add a calendar reminder for Day 14 (triage deadline) and Day 80 (fix deadline warning)

Day 7-14   Triage
           → Reproduce or refute. If you can't reproduce, ask the reporter for more detail —
             that doesn't reset the clock, but it's a legitimate triage step.
           → Score severity using docs/security/severity-rubric.md.
           → Decide: fix, dispute (not a vuln), or accept (known limitation).
           → Send the severity-assessment template (docs/security/templates/severity-assessment.md).

Day 14-N   Private fix
           → Work in a private branch — do NOT open a public issue, do NOT mention
             the vuln in a public commit message until the advisory is ready to publish.
           → If using GitHub Security Advisories, the advisory draft IS your private workspace —
             collaborators can be added to the draft for code review.
           → Validate the fix with the reporter if they're willing.

Day N      Release + advisory
           → Cut a release through the normal pipeline (notarize, sign with EdDSA, push to appcast).
           → Release notes: call out the security fix. Don't redact details that were already
             going public in the advisory.
           → Publish the GitHub Security Advisory. Request a CVE on publish if it's High or
             Critical severity (GitHub forwards to MITRE — free, ~1-2 day turnaround).
           → Send the disclosure-publication template (docs/security/templates/disclosure-publication.md)
             with a link to the advisory + release.

Day 90     Hard deadline
           → If no fix shipped: negotiate an extension WITH THE REPORTER (in writing, by email
             or in the advisory draft). Their assent extends the embargo.
           → Silence = the reporter is free to publish on day 91. They warned you. SECURITY.md
             promised this. Don't be surprised.
```

---

## Calendar discipline

The day-90 deadline is a hard date, not a vibes date. Set these the moment a report is acknowledged:

- **Day 14** — triage deadline. Block 1-2 hours for severity scoring + assessment reply.
- **Day 60** — soft warning. Check fix status. If the fix isn't on a release branch yet, pull the schedule forward.
- **Day 80** — hard warning. If the fix isn't merged and through a release rehearsal by day 80, you're either negotiating an extension this week or shipping unverified on day 89. Neither is good — day 80 is when you make the call.

Use whichever calendar lives next to your daily flow (Apple Calendar, Google Calendar, etc.). The infrastructure isn't important; the recurring touch is.

---

## What if a report turns out to be out-of-scope?

`SECURITY.md` already lists in-scope vs out-of-scope. Some reports will be:

- **Roblox infrastructure issues** — point the reporter at Roblox's HackerOne or contact channel; close the report politely.
- **Anti-detection / "RORORO is too easy to detect" / "users can delete the app"** — these are explicit non-goals. Use the *What we won't accept as findings* section of `SECURITY.md` verbatim in the reply.
- **macOS Gatekeeper / SIP / general macOS hardening** — point at Apple's bug bounty.
- **Quality bugs that aren't security** — convert to a public GitHub issue with the reporter's permission, thank them, close the security thread.

Out-of-scope reports still get an acknowledgement and a polite explanation within 7 days. The 90-day clock doesn't run because there's nothing to fix, but the reachability obligation does.

---

## GPG / signed email

`SECURITY.md` says "request a GPG public key in your initial message" — that promise needs to be cashable. **Action item:** generate a maintainer GPG key, publish the fingerprint, and either upload to keys.openpgp.org or attach to GitHub account.

One-time setup. **macOS quirk first:** if you don't have `pinentry-mac` installed, `gpg --full-generate-key` will fail with `Screen or window too small`. Fix:

```bash
# macOS prerequisite — native GUI passphrase prompt
brew install pinentry-mac
mkdir -p ~/.gnupg && chmod 700 ~/.gnupg
echo "pinentry-program /usr/local/bin/pinentry-mac" >> ~/.gnupg/gpg-agent.conf
gpgconf --kill gpg-agent
```

Then generate + publish:

```bash
# 1. Generate (interactive — pick option 9 ECC+ECC, curve 1 Curve25519,
#    expiry 0, name + email matching SECURITY.md). Passphrase prompt pops
#    in a native macOS dialog from pinentry-mac.
gpg --full-generate-key

# 2. Read the fingerprint
gpg --list-keys --fingerprint estevan@626labs.dev

# 3. Export the PUBLIC key (safe to share; ~/Documents is fine even if
#    iCloud-synced — public keys are meant to be shared)
gpg --armor --export estevan@626labs.dev > ~/Documents/626labs-pgp-public.asc

# 4. Upload to keys.openpgp.org — open the returned URL in a browser
#    and click the verification email keys.openpgp.org sends.
curl -sS -F "keytext=@$HOME/Documents/626labs-pgp-public.asc" https://keys.openpgp.org/vks/v1/upload

# 5. Add to GitHub (discoverable via github.com/<user>.gpg)
gh gpg-key add ~/Documents/626labs-pgp-public.asc

# 6. Export the PRIVATE key to /tmp for 1Password backup.
#    DO NOT WRITE THIS TO ~/Documents OR ~/Desktop — those are
#    iCloud-Drive-synced by default and would propagate the private
#    key to every Apple device on the iCloud account. Use /tmp.
gpg --export-secret-keys --armor estevan@626labs.dev > /tmp/626labs-pgp-private.asc

# 7. Open 1Password → New Secure Note → attach /tmp/626labs-pgp-private.asc
#    + the passphrase as a separate field. Save.

# 8. Wipe the on-disk private-key export
rm /tmp/626labs-pgp-private.asc
```

Then update `SECURITY.md` to publish the fingerprint inline so researchers can verify before sending sensitive details.

---

## CVE assignment

When publishing a High or Critical advisory through GitHub Security Advisories:

1. In the advisory draft, click **"Request CVE"** before publishing.
2. GitHub forwards to MITRE as a CNA-LR (CVE Numbering Authority of Last Resort). Free.
3. CVE typically issued within 1-2 business days, sometimes before publish.
4. The CVE shows up on the published advisory and is searchable on cve.mitre.org and nvd.nist.gov.

Medium and Low severity don't need CVEs. Most projects don't bother for sub-Critical issues; the GitHub Security Advisory itself is the authoritative record.

---

## After the fact

Within a week of any published advisory, append a one-liner to `docs/decisions/` (an ADR or a numbered post-mortem) covering:

- What was the issue.
- What was the fix.
- What does the new mitigation look like in the code (file + line refs).
- Anything that changed in the threat model — re-run the affected STRIDE row in [`docs/generated/threat-model.md`](../generated/threat-model.md).

This is the institutional memory step. Three months from now you won't remember CVE-2026-xxxxx without it.

---

## Templates index

- [`templates/acknowledgement.md`](templates/acknowledgement.md) — Day 0-7 reply.
- [`templates/severity-assessment.md`](templates/severity-assessment.md) — Day 7-14 reply with severity + timeline.
- [`templates/disclosure-publication.md`](templates/disclosure-publication.md) — Release-day publication.

## See also

- [`SECURITY.md`](../../SECURITY.md) — the public-facing policy this runbook implements.
- [`docs/security/severity-rubric.md`](severity-rubric.md) — Critical / High / Medium / Low buckets + fix windows.
- [`docs/generated/threat-model.md`](../generated/threat-model.md) — STRIDE-shaped threat model.
- [GitHub Security Advisories docs](https://docs.github.com/en/code-security/security-advisories/repository-security-advisories) — official reference for the PVR + advisory flow.
