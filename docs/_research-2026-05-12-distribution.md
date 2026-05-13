# Research synthesis — cookie isolation distribution path (Task 4.5)

> Captured 2026-05-12 from three parallel research agents. The reports themselves are summarized inline below; full reports lived in chat. Treat this as the durable record of what we found before committing to a distribution approach.

## Headline

**The architecture we shipped on `fix/launcher-cookie-isolation` is mainstream within the macOS multi-Roblox-launcher space — at least three independent tools (Raptor-Manager, Nitrogen, celestial-ui) converged on the same regex-rewrite-CFBundleIdentifier-per-account recipe.** The public-web community has noticed the cookie-collision bug as a *symptom cluster* (Error 264, teleport-fails-with-same-account, "logged me out of both") but has not correctly named the root cause. We are *solving an unsolved problem* with respect to public diagnosis, even though the *fix mechanism* is converged.

**The distribution question (Task 4.5) is functionally answered: Nitrogen ships ad-hoc `codesign --force --deep --sign -` to thousands of users in production via `curl | bash` install. Ad-hoc signing IS the working distribution mechanism for runtime re-signing of `/Applications/Roblox.app` copies in the wild.** Our specific recipe (no `--deep`, `disable-library-validation` entitlement) is *narrower* than Nitrogen's and untested at scale; we should verify it works with ad-hoc identity or fall back to Nitrogen's broader recipe.

## Agent 1 — Tool landscape

Survey of 12 named tools, 6 read at source level. Key findings:

- **Group 1 (singleton-break only, has the cookie bug):** `Insadem/multi-roblox-macos` (Go, the canonical reference), `SomeRandomGuy45/MacBlox` (Obj-C++, derivative). Both `cp -a` + flip `LSMultipleInstancesProhibited` + `sem_unlink` + `open -a`. Neither rewrites bundle ID. Neither isolates cookies. **The bug we just fixed exists in both.**
- **Group 2 (bundle-ID rewrite + cookie isolation = our architecture):**
  - **`DollarNoob/Raptor-Manager`** — Tauri/Rust, MIT, actively maintained. Closest direct analog. `modify_bundle_identifier` regex-rewrite + `~/Library/HTTPStorages/com.roblox.RobloxPlayer.{profileId}.binarycookies`. Re-signs only the Delta-sandboxed path with `-s -`. Notarized parent app.
  - **`JadXV/Nitrogen`** — Electron, very actively maintained. Mutates `/Applications/Roblox.app` *in place*, regex-replaces CFBundleIdentifier, `xattr -cr + codesign --force --deep --sign -`, spawns, **resets the bundle ID 5 seconds later**. Ships unsigned via `curl | bash`. Thousands of users in production.
  - **`imeowforcash/celestial-ui`** — Tauri/Rust. `cp -R` + regex-rewrite + cookie write + `lsregister -f` + spawn. **No `codesign` step at all.** Uses macOS Keychain for cookie blob storage (clever — confirmed by their in-source comment: *"celestial is the only one that uses keychain instead of a json, so this is actually the safest"*).
- **Group 3 (single-account switchers, not concurrent):** `AppleBlox/appleblox` (the "Bloxstrap for Mac"), `zzyil/roblox-account-manager`, `6E6B/altman` (deprecated).
- **Not actually applicable:** Roblominer (different product entirely — a Robux-mining mobile game), MultiBloxer/Velocity/Fishstrap/Voxel/Avaluate/Xelvanta/Dashbloxx (Windows-only), `iigordev/multiroblox-launcher` (404'd — repo deleted as of May 2026, our PROVENANCE.txt + docs/prd.md need to drop the dead links).

**The standout finding:** Nobody else in the multi-launcher space adds `com.apple.security.cs.disable-library-validation`. Raptor skips re-signing for the vanilla path; Nitrogen does `--deep --sign -` with no custom entitlements; celestial-ui doesn't re-sign at all. **Three working tools in production without our entitlement is evidence the entitlement might not be strictly necessary.** Worth testing whether our fix works without it.

## Agent 2 — Apple signing theory

Verdict from Apple-docs and DTS-engineer-statement research: **ad-hoc + `--options runtime` + `disable-library-validation` entitlement is unverified-and-probably-broken in theory.** Quinn (Apple DTS) on Developer Forums has said multiple variations of *"ad-hoc signatures can't carry restricted entitlements"* and *"you can't keep library validation on if you use an ad-hoc signature."* Whether `disable-library-validation` counts as "restricted" is the unsettled question; Apple's docs are silent.

**Agent 2's recommendation:** abandon runtime re-signing entirely; adopt the Parall pattern (`github.com/JulyIghor/Parall` — MAS-distributed multi-instance launcher). Parall uses **HOME env override at `posix_spawn` time** with the original app binary untouched. No re-sign, no distribution problem.

**Why we can't use Parall's pattern as-is:** We already tested it in plan v1 (the HOME-injection + direct-binary-spawn architecture). It failed: direct binary spawn produces a process that's alive and rendering UI but isn't LaunchServices-registered, so `kAEGetURL` URL delivery fails. Roblox specifically needs the `roblox-player://1+launchmode:play+gameinfo:...` URL delivered at launch — without it, Roblox lands at home screen. argv, osascript, and direct AE-to-pid all failed. **The Parall pattern works for apps that don't need URL parameter delivery; Roblox does.**

**Where Agent 2 disagrees with reality:** Their "ad-hoc theoretically broken" position contradicts Agent 1's "Nitrogen ships ad-hoc to thousands of users." Either Apple's theoretical signal doesn't match practice, or Nitrogen's variant (`--deep --sign -` without our entitlement) avoids the failure mode Apple warns about. Most likely the latter — Nitrogen ad-hoc-signs *all* binaries including embedded helpers, so library validation has nothing to enforce (no team mismatch because there's no team anywhere). Our variant keeps inner helpers Roblox-team-signed and only ad-hocs the outer shell, which IS the failure mode Apple warns about.

## Agent 3 — Community signal

Surveyed AppleBlox issues, Insadem issues, Roblox DevForum, Reddit, Mac forums, YouTube tutorials.

**The bug is widely felt but never correctly diagnosed in public.** Three folk-names for the same root cause:

- "Error 264 — same account launched from different device" — what Roblox's server shows when two clients present the same cookie
- "Teleport fails — thinks the same account is joining the same server" — same identity collision, teleport-flow visibility
- "Logged me out of both" — auto-rejoin tick collision

Tool maintainers' workarounds amount to *symptom-evasion*, not cause-fix:

- AppleBlox collaborator (#82): *"You have to join a game before opening a new instance, also you can't teleport"*
- AppleBlox collaborator (#107): *"Multi-instance is buggy and unsupported, sorry"* (closed)

No public diagnosis names the `CFBundleIdentifier` → `HTTPStorages` collision. **No Roblox engineer has acknowledged the bug in any public forum I could find.** We are ahead on root-cause naming; the architectural fix (bundle-ID-rewrite per account) is converged with the other Group 2 tools but the *understanding* is ours.

## Reconciliation + decision

Three reports, two relevant findings:

1. **Ad-hoc `codesign` re-signing works in production** (Nitrogen evidence). Distribution is solvable.
2. **Our specific recipe** (no `--deep`, with `disable-library-validation` entitlement) is narrower than Nitrogen's and untested with ad-hoc identity. The theory question is real — Apple has signaled ad-hoc may not honor restricted entitlements.

**The test that settles it:** run our existing recipe with `--sign -` instead of `Developer ID Application: …` and see what happens.

- If it launches and plays → ship as-is with `--sign -` for end users.
- If it doesn't → fall back to Nitrogen's variant (`--force --deep --sign -` without entitlement). Lose Hardened Runtime on the re-signed copy; rely on ad-hoc-everything matching itself for library validation purposes.
- If neither works → reconsider; possibly punt to local-dev-only for v0.7.0 and design a real distribution architecture for v0.8.0.

**This is exactly Task 4.5 as planned, with stronger evidence the ad-hoc path will work.** Running the test now.

## Implications for the plan / ADR

After Task 4.5 settles, the plan + ADR 0009 should record:

- The competitive landscape (Raptor, Nitrogen, celestial-ui converged on the same recipe)
- Why we chose our specific entitlement-based variant over Nitrogen's `--deep` variant (Hardened Runtime preservation, minimal blast radius on Roblox's embedded helper signatures)
- The community-signal finding that we're naming the root cause publicly for the first time
- Dead-link cleanup for `PROVENANCE.txt` and `docs/prd.md` (iigordev/multiroblox-launcher 404'd)

## Sources captured (links the agents cited)

- `github.com/Insadem/multi-roblox-macos`
- `github.com/SomeRandomGuy45/MacBlox`
- `github.com/DollarNoob/Raptor-Manager`
- `github.com/JadXV/Nitrogen`
- `github.com/imeowforcash/celestial-ui`
- `github.com/AppleBlox/appleblox` (issues #11, #82, #107, #114)
- `github.com/JulyIghor/Parall` (HOME-override pattern, no re-sign)
- Apple Developer Forums threads 694873, 706437, 691574, 126895, 673889, 723669
- `alfiecg.uk/2024/01/06/Ad-hoc-signing.html` (kernel internals of ad-hoc identity)
- `eclecticlight.co` Howard Oakley posts on entitlements + signing
- `lapcatsoftware.com/articles/hardened-runtime-sandboxing.html` (Jeff Johnson)
