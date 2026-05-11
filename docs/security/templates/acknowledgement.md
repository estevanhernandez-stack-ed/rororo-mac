# Acknowledgement template

**When to send:** within 7 days of receiving any security report — email or GitHub Security Advisory. Includes out-of-scope reports.

**What it does:** confirms receipt, sets the triage timeline, gives the reporter a reference to expect a real assessment by.

**Editing notes:**

- Fill `{REPORT_DATE}` with the date the report was received.
- Fill `{TRIAGE_DEADLINE}` with `{REPORT_DATE} + 14 days`.
- If the report came via email and PVR is enabled, *encourage* (don't require) the reporter to move the conversation into a GitHub Security Advisory draft — it makes the audit trail cleaner and handles the embargo automatically. Don't force the switch; some researchers prefer email.

---

## Template body

```
Subject: Re: <reporter's subject line>

Thanks for the report — received on {REPORT_DATE}. This message
acknowledges receipt; a full assessment will follow.

What happens next:

  • I'll triage and assess severity by {TRIAGE_DEADLINE} (within 14 days
    of receipt per the policy in our SECURITY.md).
  • Once I've reproduced and scored the issue, you'll get a reply with
    the severity, the expected fix window, and any clarifying questions.
  • Private fix work happens in a private branch; public release notes
    and a GitHub Security Advisory go out at fix time. You're welcome
    to be credited in the advisory — let me know how you'd like to be
    named, or say nothing and you'll be credited as "External reporter"
    by default.

A few quick checks while I work on this:

  1. Was the report submitted via email only, or also through GitHub
     Security Advisories? If you'd prefer, the GitHub flow auto-handles
     the embargo and lets us collaborate on the fix privately —
     https://github.com/estevanhernandez-stack-ed/rororo-mac/security/advisories/new

  2. If you sent the report unencrypted and would prefer to share
     additional detail over GPG, my public key fingerprint is:
       E52F 4A54 4426 1AE7 0D12  D817 B928 75D4 F623 6B8A
     Fetch via: gpg --keyserver hkps://keys.openpgp.org \
                    --recv-keys E52F4A5444261AE70D12D817B92875D4F6236B8A
     Verify the full fingerprint matches before encrypting.

  3. Any pseudonym, handle, or attribution preferences for the eventual
     advisory? Let me know now so the published advisory matches.

Thanks again for taking the time to report this responsibly. I'll be
in touch by {TRIAGE_DEADLINE}.

— Estevan
   RORORO Mac maintainer
   estevan@626labs.dev
```

---

## When NOT to use this template

- **Spam / phishing / generic "we found vulnerabilities in your site" with no specifics.** Ignore.
- **Already-public findings.** If the issue is already public (GitHub issue, social post, indexed exploit), this isn't a private disclosure anymore — go straight to the severity assessment + plan to publish.
- **Reporter asking a question, not reporting a vuln.** Use a normal email reply, not this template.

## Calendar hooks to set when sending this

- **Day 14 (the triage deadline)** — block 1-2 hours for severity scoring + assessment reply.
- **Day 60 (soft warning)** — check fix-in-progress status; pull schedule forward if needed.
- **Day 80 (hard warning)** — extension-or-ship decision call.
