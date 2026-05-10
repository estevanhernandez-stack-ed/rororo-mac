# Plan — Slope D, Wave 3: Full-fidelity record-and-replay

**Date:** 2026-05-10
**Status:** Not started — ready for handoff
**Slope:** D-3 (record-and-replay). Companion to ADR 0007.
**Sibling plan:** `docs/plans/d1-d2-smarter-cycler.md` (D-1 + D-2 — shipped 2026-05-10, commits `fb5eaaa` + `8a9c9d9` + `aa8ccf1`).

## What's already on the ground

Wave D-1 shipped these artifacts that D-3 builds on. Don't re-implement; just consume:

- **`WindowRectTracker`** (`App/RORORO/Domain/AutoKeys/WindowRectTracker.swift`) — actor that caches per-pid screen rects via AX. D-3's player calls `await tracker.rect(for: pid)` to get the live window origin before translating relative mouse coords to absolute screen coords. D-3's recorder calls the same to translate captured absolute coords to window-relative.
- **`AXUIElementRectProvider`** — production conformance behind `AXRectProvider` protocol. Already filters minimized windows.
- **`FrontmostAppProvider`** — DI seam over `NSWorkspace.frontmostApplication`. D-3's recorder uses this to gate capture (Decision 3 frontmost-only filter).
- **`WorkspaceActivationObserver`** — DI seam over `NSWorkspace.didActivateApplicationNotification`. D-3's recorder uses the same observer to pause/resume capture as Roblox loses/gains focus.
- **`KeyEventPoster`** + **`CGEventKeyEventPoster`** — keyboard event posting. D-3 mirrors this shape with `MouseEventPoster`.
- **`AutoKeysCycler` state machine** — `.stopped` / `.running` / `.paused` with reasons including `.focusStolen(byPid:)`. D-3 reuses this verbatim; the player swaps in for the step loop without touching state semantics.

## What's locked (read these before touching code)

Every meaningful decision is documented. If a code decision feels load-bearing, the rationale is here:

- **`docs/decisions/0007-full-fidelity-record-and-replay.md`** — ADR 0007, Status: Accepted. 8 decisions covering data model, mouse coord scheme, recorder UX, legacy migration, TCC posture, hard-rule reaffirmation, sharing model, and clock source. **Start here.**
- **`docs/decisions/0004-auto-keys-cycler.md`** — original cycler ADR + Slope D amendment. D-3 retracts Decisions 2 and 5 of ADR 0004 (3-key cap, per-step recorder) — see ADR 0007 Background.
- **`docs/plans/d1-d2-smarter-cycler.md`** — companion plan. The `WindowRectTracker` shape spec, coord-system conventions (AX is top-left, NSEvent is bottom-left, tracker stores top-left), DI seam patterns. D-3 follows the same conventions.
- **`CLAUDE.md`** (repo root) — hard rules. **Mouse recording is capability extension, not anti-detection.** No injection, no patching, no observation evasion. The cycler still steals focus before firing. Reaffirmed in ADR 0007 Decision 6.

## Wave breakdown — 6 waves, dependency-ordered

Each wave is its own commit (or small commit cluster). Don't merge waves in a single PR — the slope is big enough that bisecting matters if something goes wrong.

### Wave D-3.1 — Data model + migration (foundations)

User-invisible. Adds new types, makes existing types coexist with them. No behavior change yet.

**New files:**
- `App/RORORO/Domain/AutoKeys/AutoKeysAction.swift` — the 5-case enum (`keyDown` / `keyUp` / `mouseMove` / `mouseDown` / `mouseUp`) + `MouseButton` enum (`.left` / `.right`). Codable, Equatable, Sendable.
- `App/RORORO/Domain/AutoKeys/MouseEventPoster.swift` — DI seam protocol + `CGEventMouseEventPoster` production conformance. Same shape as `KeyEventPoster`. Self-tags events with `AutoKeysCyclerSourceTag` (`0x524F524F`) so the safety monitor ignores them.

**Modified files:**
- `App/RORORO/Domain/AutoKeys/AutoKeysSequence.swift` — wraps `[AutoKeysAction]`. New `.legacy([AutoKeysStep])` variant for migration. New `isShared: Bool` field (default `false`) per ADR 0007 Decision 7. New `cap: Int = 500` constant.
- `App/RORORO/Domain/AutoKeys/AutoKeysStep.swift` — kept verbatim for legacy. Don't delete.
- `App/RORORO/Domain/Account.swift` — adds `autoKeysSourceAccountId: Account.ID?` field. Default nil. Codable migration: missing field → nil.
- `App/RORORO/Domain/AccountStore.swift` — handles the new field's default. No behavior change yet (resolution lives in D-3.2).

**Tests (new file):** `App/ROROROTests/AutoKeysActionTests.swift`
- Round-trip Codable for each action case (CGPoint precision, modifier mask)
- `AutoKeysSequence` migration: legacy step-list payload decodes into `.legacy(...)` variant
- `AutoKeysSequence` migration: action-stream payload decodes into the stream variant
- `AutoKeysSequence` 500-action cap enforced at `init?(actions:)` (returns nil over cap)
- `MouseEventPoster` self-tags events (use `CGEvent.getIntegerValueField(.eventSourceUserData)` to verify)

**Acceptance:** existing test suite stays green (256 tests). New tests pass. App still launches and runs legacy sequences unchanged.

### Wave D-3.2 — Player (action-stream replay)

User-invisible until D-3.4. Adds the playback engine but nothing creates new-format sequences yet, so all live data still flows through the legacy path.

**New file:**
- `App/RORORO/Domain/AutoKeys/ActionStreamPlayer.swift` — actor that consumes `[AutoKeysAction]` and replays through `KeyEventPoster` + `MouseEventPoster` + `WindowRectTracker`. Per-action: sleep `dt`, translate `rel` → absolute via tracker, post the CGEvent. Skip-and-continue on `WindowRectTracker` reporting the target is gone (ADR 0007 Decision 2). Cancellable mid-stream via `Task.cancel()`.

**Modified files:**
- `App/RORORO/Domain/AutoKeys/AutoKeysCycler.swift` — `runLoop` switches on sequence variant:
  - `.legacy(steps)` → existing step loop (unchanged, just gated)
  - `.stream(actions)` → `await player.play(actions:, targetPid:, sourceAccountIdResolver: ...)`
  - Both share the existing focus-then-fire-then-verify pattern and the existing post-fire focus-theft check
- `App/RORORO/Domain/AutoKeys/CycleBudget.swift` — `estimate` sums per-action `dt` for stream variants and per-step `delayAfter` for legacy. Same warn/cap thresholds (18min / 19min) from ADR 0004 Decision 4.

**Sharing resolution lives here.** In `cycler.start()`, before building the target list: for each account, if `autoKeysSourceAccountId` is set, look up that account's `autoKeys` and substitute. If the source account is gone (deleted, recording un-shared, source `autoKeys` nil), skip the consumer with a log and surface it in the budget summary.

**Tests:** add to `App/ROROROTests/AutoKeysCyclerTests.swift`
- Action-stream path: cycler replays an action stream verbatim through fake posters
- Mid-replay window-closed: `WindowRectTracker` returns nil for target → player aborts, cycler continues
- Sharing reference: account B with `autoKeysSourceAccountId = A.id` runs A's sequence
- Sharing orphan: account B references gone account A → B is skipped with log
- Cancellation: cycler `stop()` mid-action-stream → player aborts cleanly

**Acceptance:** legacy path still green. New tests pass. Action-stream playback works in unit tests against fakes.

### Wave D-3.3 — Recorder (capture)

User-invisible until D-3.4 wires it to a sheet. Standalone capture engine.

**New file:**
- `App/RORORO/Domain/AutoKeys/ActionStreamRecorder.swift` — actor that consumes events from the existing `EventTapping` source, measures `dt` via `CACurrentMediaTime()` (ADR 0007 Decision 8), and translates absolute mouse coords to window-relative via `WindowRectTracker`. Gates capture on `FrontmostAppProvider.currentFrontmostPid() == targetPid` (Decision 3 frontmost-only filter). Enforces 500-action cap. Exposes `currentCount`, `elapsed`, `isCapturePaused` (Roblox not frontmost) as observable state for the UI.

**Modified file:**
- `App/RORORO/Domain/AutoKeys/EventTapping.swift` — likely no change; the existing tap already surfaces the events the recorder needs. Verify the tap captures `.mouseMoved` events with screen-coord positions (it should, via `NSEvent.mouseLocation`).

**Tests (new file):** `App/ROROROTests/ActionStreamRecorderTests.swift`
- `dt` measurement: inject synthetic events with known timestamps, verify recorded `dt` matches (using a fake clock seam)
- Frontmost gating: events arriving while a non-target PID is frontmost are dropped
- Frontmost-pause indicator: `isCapturePaused` flips true when target loses focus, false on return
- Coord translation: absolute event coords minus tracker rect origin = stored `rel`
- 500-action cap: recorder refuses to append past 500; surfaces `cappedAt` flag

**Acceptance:** unit tests green. Recorder produces valid `[AutoKeysAction]` streams; player from D-3.2 can replay them in a round-trip test.

### Wave D-3.4 — Recorder UI

First user-visible D-3 surface. Adds the Record / Stop sheet; doesn't remove the old per-step recorder (kept until D-3.6 cleanup).

**New file:**
- `App/RORORO/UI/AutoKeysRecorderV2Sheet.swift` — Record / Stop UX per ADR 0007 Decision 3. Live action count (X / 500), elapsed time, "Roblox not frontmost — capture paused" indicator. Post-record: share toggle (`isShared`), Save / Discard buttons. Mirrors the existing `AutoKeysRecorderSheet`'s placement on the account row but with a different presentation flow.

**Modified files:**
- `App/RORORO/UI/AccountsListView.swift` — the per-account "Record auto-keys" button presents `AutoKeysRecorderV2Sheet` instead of the old `AutoKeysRecorderSheet` for new recordings. Existing legacy sequences still display via the existing badge.
- `App/RORORO/UI/AutoKeysRowBadge.swift` — handle `.stream(actions)` variant: "X actions, Y.Zs" instead of the existing "N keys" text.

**Manual test plan:**
1. Open a configured account row. Tap Record. Verify the V2 sheet appears.
2. Click Record toggle. Switch to Roblox. Do a 5-second sequence (WASD + spacebar + one click). Switch back to RORORO. Click Stop.
3. Verify the action count + elapsed time look right (count > 5, elapsed ≈ 5s).
4. Save. Verify the row badge updates to show the new action-stream sequence.
5. Press Play in the cycler toolbar. Verify the sequence replays in Roblox.

**Acceptance:** can record + replay a sequence end-to-end. Existing legacy accounts still work.

### Wave D-3.5 — Sharing UI

The data model from D-3.1 already supports sharing; this wave wires it to the UI.

**Modified files:**
- `App/RORORO/UI/AutoKeysRecorderV2Sheet.swift` — post-record share toggle persists `isShared` on the sequence. Already in D-3.4; this wave just verifies it's there.
- `App/RORORO/UI/AccountsListView.swift` — per-account row gains a "Use shared recording" picker. Shows every other account whose `autoKeys?.isShared == true`. Selecting one sets `autoKeysSourceAccountId`. Clearing reverts to own recording.
- `App/RORORO/UI/AutoKeysRowBadge.swift` — badge shows "using [OwnerAccount]'s recording" when `autoKeysSourceAccountId` is set.

**Edge cases to handle:**
- Source account deleted → consumer's badge shows "shared source missing" + offers to clear the reference
- Source account un-shares → same as above; the cycler skips consumers with broken references and the badge surfaces the broken state on next load

**Manual test plan:**
1. Record on Account A. Toggle Share. Save.
2. On Account B's row, open the "Use shared recording" picker. Pick A's recording. Save.
3. Press Play. Verify both A and B fire the same sequence in their respective Roblox windows.
4. Delete Account A. Verify Account B's badge surfaces "shared source missing."

**Acceptance:** sharing works end-to-end. Orphan handling is graceful.

### Wave D-3.6 — Cleanup + smoke

- Remove the old `AutoKeysRecorderSheet` presentation path (file stays for any in-flight migration code; UI surface point is removed).
- Add a "Legacy recording — re-record to enable mouse" hint on legacy-variant badges.
- Full smoke test against real Roblox:
  1. New action-stream recording: record 30 seconds, replay against multi-instance, verify mouse clicks land
  2. Window-move robustness: record, move Roblox window, replay, clicks still hit right spots
  3. Window-resize robustness: same with a 20% resize
  4. Legacy migration: load an ADR 0004 config, verify it runs unchanged
  5. Sharing: A records + shares, B picks A's recording, both run
  6. Mid-replay theft: cmd-tab to Safari mid-replay, verify cycler pauses `.focusStolen` (D-2 behavior preserved)
  7. Cap enforcement: try to record past 500 actions, verify cap banner
- Update ADR 0004 with a final amendment note marking ADR 0007 shipped + linking to this plan

## Risks

- **TCC for mouse events.** Decision 5 says mouse posting piggybacks on the existing Accessibility consent. Verify this on the first mouse-post in D-3.2 — if macOS prompts again, the plan needs a small adjustment (an extra TCC bucket request, same UX as the kill-key Input Monitoring grant).
- **Cycle budget math under action streams.** Long action streams with tight `dt` values can push past the 19-minute hard cap quickly. The recorder's live count + elapsed display mitigates this, but the validator at save time and at cycler start needs to be honest.
- **`ActionStreamPlayer` cancellation.** The player must handle `Task.cancel()` cleanly mid-action (between the `dt` sleep and the post call). Otherwise a `cycler.stop()` mid-replay leaves a keyDown pending without a matching keyUp — game thinks the key is still held. Always pair down/up on cancellation cleanup.
- **Window-rect freshness.** D-1's tracker refreshes on each focus. For action-stream playback, the rect is refreshed once per target per cycle (at focus time). If the user moves the window mid-replay, mouse coords land at the old position. Acceptable for v1 — re-refreshing on every action is too expensive. If friction surfaces, add a per-action rect-changed check.
- **Cross-coord-system bugs.** AX rects are top-left origin; NSEvent positions are bottom-left. Tracker stores top-left. Recorder converts incoming NSEvent positions to top-left before storing relatives. Player translates relatives to absolute top-left, then to bottom-left for the CGEvent post. **One screen-height-flip per axis; easy to double-flip and end up with mirrored coords. Add a coord-system assertion in tests.**

## Non-goals (out of scope for D-3)

- **Edit-in-place recording.** Re-record only. ADR 0007 Decision 3 — interactive trim UI is a future ADR if friction surfaces.
- **Multiple recordings per account.** One per account, with sharing for the multi-account use case. ADR 0007 Decision 7.
- **TinyTask `.rec` interop.** Inspiration only, no file-format lift. ADR 0007 Decision 3 + Approaches considered.
- **Per-action rect-changed re-tracking during replay.** Once-per-target refresh is the v1 contract.
- **A library of recordings.** No `AutoKeysRecording` first-class entity in v1; sharing flows account → account via reference. If a library becomes useful (e.g., "import recording from another machine"), that's a future ADR.

## Start here (handoff entry point)

1. Read `docs/decisions/0007-full-fidelity-record-and-replay.md` (the ADR — what + why).
2. Read this plan (the how + order).
3. Read `docs/plans/d1-d2-smarter-cycler.md` for the coord-system conventions and DI seam patterns this slope follows.
4. Start D-3.1 with TDD: write `AutoKeysActionTests.swift` first, then the production types. Build green is the gate.
5. One wave per commit. Don't bundle D-3.1 and D-3.2 — the data-model commit should be independently revertable.

## References

- ADR 0007 — Full-fidelity record-and-replay (the spec).
- ADR 0004 — Auto-keys cycler (what this slope retracts and amends).
- `docs/plans/d1-d2-smarter-cycler.md` — sibling plan for the shipped substrate.
- `CLAUDE.md` (repo root) — hard rules.
- `~/.claude/CLAUDE.md` — The Architect persona + voice DNA for working/technical register.
