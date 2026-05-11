# Disclosure publication template

**When to send:** the day the fix release ships AND the GitHub Security Advisory publishes. This is the final reporter communication of the cycle — confirming public disclosure, crediting the reporter, and linking to everything.

**What it does:** closes the loop with the reporter, makes the credit + CVE references public, and signals the embargo is over.

**Editing notes:**

- Fill `{ADVISORY_URL}` — the public URL of the published GitHub Security Advisory.
- Fill `{RELEASE_TAG}` — the version that contains the fix (e.g., `v0.1.1`).
- Fill `{RELEASE_URL}` — link to the GitHub release.
- Fill `{CVE_ID}` if a CVE was issued (Critical / High); omit the CVE line otherwise.
- Fill `{REPORTER_CREDIT}` with whatever attribution the reporter requested in the acknowledgement / assessment replies.

---

## Template body — reporter notification

```
Subject: <reporter's subject line> — Public disclosure

The advisory + fix are live as of today.

  • GitHub Security Advisory: {ADVISORY_URL}
  • Release: {RELEASE_TAG} — {RELEASE_URL}
  • CVE: {CVE_ID}    <omit this line if no CVE>
  • Credit: {REPORTER_CREDIT}

A couple of asks now that the embargo is over:

  1. If you want to publish your own write-up, you're welcome to —
     please link back to {ADVISORY_URL} as the authoritative reference.
  2. If anything in the advisory body misrepresents the issue, what
     was reproduced, or the fix, let me know and I'll edit. I'd rather
     get the technical record right than be defensive about it.
  3. If you'd like attribution changed (different handle, link to a
     blog, redact entirely), say so and I'll update the advisory body.

Thanks again. This is the part of OSS that works because people like
you take the time to report responsibly.

— Estevan
   estevan@626labs.dev
```

---

## Release notes copy (separate — for the GitHub release body)

The release that ships the fix should call out the security fix in its release notes. Don't redact details that are already public in the advisory.

```
## Security

This release fixes {SEVERITY}-severity issue {CVE_ID or ADVISORY_REF}:
<one-sentence description of the issue, no more than the advisory body
already states>.

  • Advisory: {ADVISORY_URL}
  • Reporter: {REPORTER_CREDIT}

Users on older versions should update immediately via Sparkle auto-update
or by re-downloading from the Releases page.
```

---

## GitHub Security Advisory body (skeleton)

The advisory body is what shows up at `github.com/<owner>/<repo>/security/advisories/<id>`. GitHub also indexes this on the GitHub Advisory Database — public, searchable, and consumed by package managers / SBOM tooling. Write it for a future security-conscious reader who's never heard of RORORO.

```markdown
## Summary

<One-paragraph plain-English description. What's the issue, what's the
impact, who's affected.>

## Affected versions

`RORORO Mac` versions ≤ `<last vulnerable version>`. Fixed in `<RELEASE_TAG>`.

## Severity

`{SEVERITY}` (per [our severity rubric](https://github.com/estevanhernandez-stack-ed/rororo-mac/blob/main/docs/security/severity-rubric.md)).
CVSS 3.1: `<vector>` — `<base score>` `<qualitative>`. <Omit CVSS if not requesting a CVE.>

## Impact

<2-4 sentences. What can an attacker actually do? What's the prerequisite
(user interaction? local access? specific permission state?)>

## Mitigation

Upgrade to `<RELEASE_TAG>` or later. Sparkle auto-update will fetch
the new version on next launch. If auto-update isn't available, re-download
from the [Releases page](https://github.com/estevanhernandez-stack-ed/rororo-mac/releases).

Users who cannot upgrade immediately should <workaround if one exists,
or "no documented workaround exists; upgrading is the only mitigation"
if not>.

## Root cause

<3-6 sentences on what was wrong in the code. File + line references where
appropriate. Don't redact — the fix is already public; the post-mortem
helps everyone calibrate.>

## Fix

<2-4 sentences on what the fix does. Link to the commit or PR.>

## Credit

Discovered and reported by {REPORTER_CREDIT}. Reported on {REPORT_DATE};
fixed in {RELEASE_TAG} on {RELEASE_DATE}.

## Timeline

  • {REPORT_DATE} — Report received.
  • {REPORT_DATE + n} — Acknowledged + triage started.
  • {REPORT_DATE + n} — Severity assessed: {SEVERITY}.
  • {FIX_BRANCH_DATE} — Private fix branch created.
  • {VALIDATION_DATE} — Fix validated by <reporter / maintainer>.
  • {RELEASE_DATE} — Release {RELEASE_TAG} published.
  • {DISCLOSURE_DATE} — This advisory published.

## References

  • Threat model: [docs/generated/threat-model.md](https://github.com/estevanhernandez-stack-ed/rororo-mac/blob/main/docs/generated/threat-model.md)
  • Security policy: [SECURITY.md](https://github.com/estevanhernandez-stack-ed/rororo-mac/blob/main/SECURITY.md)
```

---

## After publication — update the threat model

Within a week of publishing the advisory, append a row to the relevant STRIDE section in [`docs/generated/threat-model.md`](../../generated/threat-model.md) marking the vector as **Mitigated** (or **Partially mitigated**) with a link to the advisory. The threat model is the institutional memory; advisories without corresponding threat-model updates drift out of date.

If the advisory revealed a structural gap (not just a single bug), open an ADR in [`docs/decisions/`](../../decisions/) capturing what changed in the design posture as a result.

---

## When NOT to use this template

- **The embargo broke and you're publishing on day 89 with no fix.** Different template needed — you're explaining why the fix didn't ship in time and what's coming next. Don't dress it up as a normal publication.
- **A Low-severity issue that doesn't warrant an advisory.** Some Lows just close as resolved in a release note with no public advisory. The reporter still gets a thank-you note + credit in the changelog if they want it.
