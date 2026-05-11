# Severity assessment template

**When to send:** within 14 days of receiving the report. Follows the acknowledgement template. This is the message where you commit to a severity bucket + a fix window.

**What it does:** confirms reproduction (or refutation), names the severity per the rubric, gives the reporter a target fix date, and opens the door for collaboration on the fix.

**Editing notes:**

- Fill `{REPORT_DATE}` with the date the report was received.
- Fill `{SEVERITY}` with one of `Critical | High | Medium | Low` per [`docs/security/severity-rubric.md`](../severity-rubric.md).
- Fill `{TARGET_FIX_DATE}` with the day-N deadline from the rubric:
  - Critical: `{REPORT_DATE} + 30 days`
  - High: `{REPORT_DATE} + 60 days`
  - Medium / Low: `{REPORT_DATE} + 90 days`
- For out-of-scope reports, use the **Disputed / out-of-scope** variant at the bottom instead.

---

## Template body — accepted finding

```
Subject: Re: <reporter's subject line> — Severity assessment

Following up on the report from {REPORT_DATE}.

Reproduction: Confirmed. <one-sentence summary of what was reproduced
on what config — e.g., "Reproduced on macOS 15.7.5 against
RORORO Mac v0.6.0 in <relevant config>.">

Severity: {SEVERITY}

Rationale: <2-3 sentences referencing the severity rubric. Example for
a Critical: "Cookie leak without user interaction — a third-party
process can read .ROBLOSECURITY values from <leak surface> as long as
<condition>. Account compromise is silent. This is Critical per
docs/security/severity-rubric.md.">

Target fix date: {TARGET_FIX_DATE} (per the {SEVERITY} bucket in our
severity rubric — <30 days for Critical, 60 for High, 90 for Medium
or Low — match this to {SEVERITY}>).

What happens next:

  • Private fix work in a non-public branch. Tracking inside a GitHub
    Security Advisory draft for audit trail. If you'd like to collaborate
    on the fix (code review, validation), reply yes and I'll add you to
    the advisory as a collaborator.
  • At fix release: public Security Advisory + release notes calling
    out the fix. <For Critical/High only: "I'll request a CVE on
    publish — GitHub forwards to MITRE, typically issued within
    1-2 business days.">
  • You'll be credited as <pseudonym from acknowledgement reply, or
    "External reporter">. Reply now if you'd like to change attribution.

A few things I may need from you during the fix work:

  1. Validation of the fix once it's in a draft branch — would you be
     willing to confirm the issue is resolved before we publish?
  2. <Any clarifying technical question you have about the report — e.g.,
     "Does the issue persist if the user has 2FA enabled on Roblox?"
     "Did you observe the leak under <specific permission state>?">

If anything in the assessment looks off — wrong severity, missed
context, edge case I haven't accounted for — push back. I'd rather
re-score now than ship a fix that misses the real problem.

— Estevan
   estevan@626labs.dev
```

---

## Template body — Disputed / out-of-scope

```
Subject: Re: <reporter's subject line> — Out-of-scope assessment

Following up on the report from {REPORT_DATE}.

After review I don't believe this falls within the scope of RORORO Mac's
security policy. Specific reason:

  <PICK ONE AND EDIT>

  • This is a Roblox Corporation infrastructure issue. RORORO Mac talks
    to auth.roblox.com / users.roblox.com / thumbnails.roblox.com as
    a client; we don't operate those endpoints. Please report this to
    Roblox directly: <https://hackerone.com/roblox> or via Roblox's own
    contact channel.

  • This is a documented design choice, not a defect. <link to the
    relevant section of SECURITY.md "What we won't accept as findings"
    or the threat model "Out of scope / non-goals"> spells out the
    rationale.

  • The reproduction requires a non-default macOS configuration (SIP
    disabled, hardened runtime bypassed, etc.). The policy is scoped
    to default-config macOS.

  • <Custom reason — write it out.>

If you believe I've misread the scope or there's an angle I haven't
considered, please reply with the additional context and I'll re-open
the assessment. The 90-day clock isn't running on this report because
there's nothing to fix from our side, but I'll still respond.

Thanks again for taking the time to report — even out-of-scope reports
help calibrate the policy.

— Estevan
   estevan@626labs.dev
```

---

## When NOT to use this template

- **Triage is still in progress.** If you can't reproduce yet, send a brief reply asking for the missing detail — don't commit to a severity until you've reproduced or formally refuted.
- **The reporter went public before the assessment.** That's a different problem — the embargo broke, you're now writing a public advisory under time pressure. Skip the private template; publish the advisory + fix plan.
