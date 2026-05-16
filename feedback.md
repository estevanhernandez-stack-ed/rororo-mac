# RORORO Mac — feedback

> User-reported bugs and rough edges. One entry per line. Optional `[severity]` tag where severity is `critical`, `major`, `medium`, `minor`.
>
> Operator-sourced entries (from dogfooding / Atlas runners-up / session memory) land here too until real user channels exist (GH Issues / Discord / in-app widget). Mark them with `(operator)` so triage knows the source.
>
> Lines starting with `bug:`, `issue:`, `broken:`, `[bug]`, or `[issue]` are parsed by `/vibe-iterate:bug-bash`. After a bug ships a fix, the line is tagged `[fixed in PR #N]` — not deleted, so the historical record survives.

bug: [fixed in PR #5] [major] (operator) Auto-keys kill-key is unreliable — pressing the configured kill-key chord doesn't always stop the cycler / recorder / playback cleanly. Flagged at end of 2026-05-10 auto-keys session (Slope C + D-3 + D-4 ship, commit 83e7cc3); not touched since. Repro context needed — likely involves focus/active-app state during the chord press.

bug: [major] (operator) `xcodebuild test` crashes the test process during teardown of `RororoKeychain*Tests` — three test files (`RororoKeychainBootstrapTests`, `RororoKeychainItemsTests`, `RororoKeychainTests`) force-unwrap a `tempPath` keychain reference whose setup can fail under real-Keychain access. Symptom: SIGILL in `tearDown()` → `** TEST FAILED **` from xcodebuild even when individual test cases report "passed". Surfaced incidentally during the kill-key bug-bash (2026-05-15) — full-suite run produced multiple `Fatal error: Unexpectedly found nil` traps and one crash report. Untouched by the kill-key fix; deserves its own bug-bash to harden setUp/tearDown against real-Keychain failure modes.
