# ADR 0007 — Full-fidelity record-and-replay (action stream + mouse)

**Date:** 2026-05-10
**Status:** Draft
**Slope:** D-3 (record-and-replay)
**Depends on:** Wave D-1 — `WindowRectTracker` (ships before this slope lands)
**Reopens:** ADR 0004 Decision 2 (3-key cap) and Decision 5 (per-step interactive recorder) — both retracted by this ADR

## Background

ADR 0004 locked the auto-keys cycler at a 3-step keystroke sequence per account, captured via a per-step interactive recorder (press a key → enter a delay → repeat to a max of 3). That cap covered the v1 use case — jump-spam plus two equipment binds — and the recorder UX was bounded by the cap. Both choices were correct for the slope they shipped on.

D-3 reopens both. The user wants to record a realistic in-game session — keyboard and mouse, including movement and click sequences that exceed any plausible 3-step cap. The recorder UX has to scale past the per-step prompt loop, and the data model has to grow past keys-only.

This is a deliberate, one-way break with ADR 0004. The cap goes. The interactive recorder goes. Both decisions retract — not amend — because the new model isn't a superset of the old API, it's a different shape (action stream vs step list). Legacy data migrates transparently (Decision 4) so no user is forced to re-record.

The hard rules from `CLAUDE.md` still bind. **Mouse-coordinate recording is capability extension, not anti-detection.** The cycler still steals focus before firing. No injection, no patching, no observation evasion. We post `CGEvent`s through the same public APIs we use today. The TinyTask reference (Decision 3) is *interaction shape only* — TinyTask is Windows freeware whose author welcomes others building from its UX; we don't lift its file format (which isn't public anyway) and we don't promise `.rec` interop.

## Decision 1 — Action stream replaces capped step list

**Decision:** `AutoKeysSequence` becomes a wrapper over `[AutoKeysAction]`. The action enum:

```swift
enum AutoKeysAction {
  case keyDown(CGKeyCode, modifiers: UInt, dt: TimeInterval)
  case keyUp(CGKeyCode, modifiers: UInt, dt: TimeInterval)
  case mouseMove(rel: CGPoint, dt: TimeInterval)
  case mouseDown(MouseButton, rel: CGPoint, dt: TimeInterval)
  case mouseUp(MouseButton, rel: CGPoint, dt: TimeInterval)
}
```

The new cap is ~500 actions per sequence — high enough to capture a realistic 30–60 s in-game loop, low enough to bound playback time and serialization size. `dt` on each action is the delay *before* firing it (time since the prior action). Empty sequence = account skipped, same as ADR 0004 Decision 3 (unchanged).

**Rationale:** The 3-key cap covered the AFK keep-alive use case; it doesn't cover the "record what I actually do for 30 seconds and loop it" use case that motivates this slope. Splitting keyDown / keyUp into separate actions (instead of the ADR 0004 `(keyCode, delayAfter)` pair that fired both back-to-back) lets recorded sequences hold a key down across other actions — required for movement-while-clicking, charged attacks, anything with overlap. The 500-action cap is a sanity bound on serialization size (~30 KB at ~60 bytes per action JSON-encoded) and on the cycler's per-account budget (Decision 4 in ADR 0004's CycleBudget math now sums `dt` across the action stream instead of `delayAfter` across steps — same formula, larger numerator).

**Consequences:** The data model gets a major version bump. Old `AutoKeysSequence` payloads in `LaunchSettingsStore` no longer decode against the new type directly; migration is handled in Decision 4. Sequences longer than 500 actions are refused at save time with a banner pointing at the cap.

## Decision 2 — Window-relative mouse coordinates

**Decision:** All `mouseMove` / `mouseDown` / `mouseUp` `rel: CGPoint` values are stored relative to the recorded Roblox window's top-left corner. At playback time, the cycler asks `WindowRectTracker` (introduced in Wave D-1) for the current window rect of the target PID and translates `rel` to absolute screen coords before posting the `CGEvent`.

**Rationale:** Absolute screen coords break the second the user moves the Roblox window — every recorded sequence becomes garbage. Window-relative coords survive window moves and survive multi-instance launches where each Roblox window lands at a different absolute position. The translation is a single per-event addition (`absolute = windowOrigin + rel`); cost is trivial.

`WindowRectTracker` is a hard dependency. Without it, mouse playback has no way to find the live window's origin and we'd either be guessing or back to absolute coords. This ADR cannot ship before Wave D-1 lands.

**Consequences:** If the user resizes the Roblox window between record and replay, click positions are still anchored to the window's top-left and will land in the same relative spot — usually correct (UI elements move with the window), occasionally wrong (resized-down windows may hide elements that were visible at record time). Documented in the recorder footer. Out-of-window coords are clamped at playback to the window's current rect — a click recorded inside the window stays inside the window even if the window shrank.

## Decision 3 — Record → do the thing → Stop (TinyTask interaction shape)

**Decision:** The recorder UX inverts to a single Record toggle. User clicks Record, performs the sequence in the Roblox window, clicks Stop. The action stream is captured verbatim — every keyDown, keyUp, mouseMove, mouseDown, mouseUp event, with measured `dt` between them. Replay is verbatim too.

**Rationale:** The per-step interactive recorder from ADR 0004 Decision 5 was bounded by the 3-step cap; it doesn't scale past ~10 actions before the prompt loop becomes its own friction. The user described the target shape directly: TinyTask's Record / Stop pattern. TinyTask is Windows-only freeware whose author has publicly welcomed others building from its UX — we take the *interaction shape* (one Record button, one Stop button, verbatim replay) and nothing else. No file format lift, no `.rec` interop, no shared internals.

**Consequences:** Editing a recording means re-recording. No edit-in-place, no per-action trim UI. Same trade ADR 0004 Decision 5 made for v1 of the original recorder — re-recording 30 seconds is cheap; building an action-stream editor is not. If friction surfaces, a future ADR can add a trim-head / trim-tail / delete-action UI on top of the stored stream (the data model supports it as-is). The recorder also surfaces a live action count and elapsed time during capture so the user can stop before hitting the 500-action cap.

## Decision 4 — Backwards-compat: legacy step lists migrate transparently

**Decision:** Existing `AutoKeysSequence` payloads in `LaunchSettingsStore` (the 3-step capped list from ADR 0004) migrate on first load to a `.legacy([AutoKeysStep])` variant inside the new sequence type. The cycler routes legacy sequences through the old step-loop path; new recordings use the action-stream path. Both paths share the same cycler state machine and the same Decision 4 cycle-budget validator from ADR 0004.

**Rationale:** No user is forced to re-record. A user who configured jump-spam under ADR 0004 keeps jump-spam working unchanged; the migration is invisible to them. The `.legacy` variant is a one-way bridge — once a user re-records an account, that account's sequence is an action stream and the legacy path is no longer involved for it. Old sequences stay legacy until re-recorded; new sequences are always action streams.

**Consequences:** `AutoKeysStep` stays in the codebase for the lifetime of the legacy path. Two recorder UIs cannot both be the primary — the new Record / Stop recorder (Decision 3) is the only UI surfaced; the old per-step recorder is removed. Users who want to add a key to a legacy sequence re-record it from scratch through the new recorder, which produces an action stream. Migration is transparent on load, not on save; the on-disk payload retains the legacy shape until the user re-records or the next major version bump cleans up.

## Decision 5 — Mouse events piggyback on existing Accessibility consent

**Decision:** Posting `CGEvent` mouse events uses the same Accessibility TCC consent already granted for keyboard events (ADR 0004 Decision 8). No new TCC bucket is requested.

**Rationale:** Accessibility consent covers all `CGEvent.post` calls — keyboard, mouse, scroll. macOS doesn't distinguish event categories within the bucket. The user grants Accessibility once for the cycler; mouse playback inherits that grant automatically. The Input Monitoring bucket added by ADR 0004 Decision 9 (engagement pause + kill key) is unchanged — that's a separate bucket for *reading* user input, which the recorder also needs (Decision 3 captures user events via the same monitor surface, tagged with our `0x524F524F` source-data so the engagement detector ignores self-events during replay).

**Consequences:** The recorder UX needs to explicitly call out that no extra prompts fire when switching from keyboard-only recording to keyboard+mouse recording. Users who already granted Accessibility for the ADR 0004 cycler see zero new dialogs. Users who haven't granted yet hit the same single banner from ADR 0004 Decision 8.

## Decision 6 — Hard-rule reaffirmation

**Decision:** This ADR explicitly affirms the `CLAUDE.md` hard rules. Mouse-coordinate recording is **capability extension**, not anti-detection. No injection. No patching. No observation evasion. No `sem_unlink` equivalents for mouse events — there's nothing to unlink. The cycler still steals focus before firing each window's actions (ADR 0004 Decision 1, unchanged).

**Rationale:** The shape of this slope — "record the user's full session including mouse" — is the closest the project has come to looking like an automation framework that could be misread as anti-detection adjacent. It isn't. We post `CGEvent`s through the same public API any accessibility tool uses. We don't inject into Roblox's process. We don't read game memory. We don't evade Hyperion or any other anti-cheat surface; if Hyperion blocks a key from being honored, we have no way to know and no mechanism to work around it. Logging this explicitly so a future reader doesn't mistake the scope expansion for a posture shift.

**Consequences:** None — this is documentation, not behavior. The reaffirmation lives in this ADR so the `feedback_app_store_posture` memory's "capability ambition + ethical clarity, App Store opt-out accepted" stance stays load-bearing across the slope.

## Implementation map

| Layer | File | What it does |
| --- | --- | --- |
| Domain — new | `App/RORORO/Domain/AutoKeys/AutoKeysAction.swift` | The action enum (5 cases) + `MouseButton` enum. |
| Domain — modified | `App/RORORO/Domain/AutoKeys/AutoKeysSequence.swift` | Wrapper over `[AutoKeysAction]` with a `.legacy([AutoKeysStep])` variant for migration. 500-action cap constant. |
| Domain — kept | `App/RORORO/Domain/AutoKeys/AutoKeysStep.swift` | Retained for legacy migration; not used by new recordings. |
| Domain — new | `App/RORORO/Domain/AutoKeys/ActionStreamRecorder.swift` | Captures events from an `EventTapping`-like source, measures `dt`, translates absolute mouse coords to window-relative via `WindowRectTracker`. |
| Domain — new | `App/RORORO/Domain/AutoKeys/ActionStreamPlayer.swift` | Replays an action stream through `KeyEventPoster` + `MouseEventPoster`. Honors per-action `dt`. Translates `rel` → absolute at fire time via `WindowRectTracker`. |
| Domain — new | `App/RORORO/Domain/AutoKeys/MouseEventPoster.swift` | Thin wrapper over `CGEvent.post` for mouse events (DI seam, mirrors `KeyEventPoster`). |
| Domain — modified | `App/RORORO/Domain/AutoKeys/AutoKeysCycler.swift` | `runLoop` switches on sequence variant: legacy → existing step loop; action stream → `ActionStreamPlayer`. State machine unchanged. |
| Domain — dependency | `App/RORORO/Domain/Windows/WindowRectTracker.swift` (Wave D-1) | Live window-rect lookup by PID. Hard prerequisite. |
| UI — new | `App/RORORO/UI/AutoKeysRecorderV2Sheet.swift` | Record / Stop UX, live action count + elapsed time, action-cap warning at ~450. |
| UI — replaced | `App/RORORO/UI/AutoKeys/AutoKeysRecorderSheet.swift` (ADR 0004) | Removed from the surface — only the V2 sheet is presented for new recordings. |

## Testing

- **Unit:**
  - `AutoKeysAction` round-trip — JSON encode/decode all 5 cases including `CGPoint` precision.
  - `AutoKeysSequence` migration — legacy step list decodes into `.legacy(...)` variant; action stream decodes into the stream variant; mixed corpus from `LaunchSettingsStore` snapshots survives.
  - `ActionStreamPlayer` ordering — DI fakes for `KeyEventPoster`, `MouseEventPoster`, `WindowRectTracker`. Verify `dt` honored, `rel` → absolute translation, clamp-to-window-rect on out-of-bounds.
  - `ActionStreamRecorder` capture — synthesize a stream of CG events, verify `dt` measured correctly and absolute → relative translation matches the recorded window's origin.
- **Integration:**
  - One XCTest records a 5-action stream (key + mouse + key) into a transparent test window, replays it, asserts both keys land and the mouse position matches. Skipped on CI (no TCC in headless runners).
- **Manual test plan** (lives in the recorder sheet's developer notes):
  1. Record a 10-second sequence in Roblox: WASD movement + spacebar jumps + one left-click. Replay. Verify movement matches and the click lands on the same on-screen element.
  2. Move the Roblox window across desktops. Replay. Verify clicks still land on the right elements (window-relative coords held).
  3. Resize the Roblox window down 20%. Replay. Verify clicks land in the same relative spot (and the recorder footer's resize-warning text is honest).
  4. Load a snapshot from an ADR 0004 build (3-step legacy sequence). Verify it migrates transparently and the cycler runs the legacy step loop for it.
  5. Try to save a 600-action sequence. Verify save is refused with a cap banner.

## Approaches considered and rejected

- **Stay with ADR 0004's 3-key cap.** Killed by scope — the cap doesn't cover mouse, doesn't cover multi-key sequences with overlap, doesn't cover the realistic in-game loops the user wants to record. Lifting the cap without changing the data shape (e.g., a 50-step list) was considered briefly and rejected — the keyDown / keyUp coupling in `AutoKeysStep` (single `keyCode` per step, no split) makes overlap impossible regardless of cap.
- **Absolute screen coordinates for mouse events.** Killed by the window-move footgun — every recording becomes garbage the moment the user moves the Roblox window. Window-relative coords (Decision 2) trade a single addition at fire time for full robustness against window position.
- **Interactive per-step recorder from ADR 0004 Decision 5.** Killed by the action-count math — at ~10 actions the per-step prompt loop is its own friction; at ~100 actions it's unusable. The TinyTask Record / Stop shape (Decision 3) is the right interaction model for verbatim capture.
- **Lift TinyTask's `.rec` file format.** Killed by two facts: TinyTask is Windows-only with no public file-format spec, and we have no interop story worth building toward. We take TinyTask's *interaction shape*; the on-disk format is our own (Swift `Codable` on the action enum).
- **Concurrent per-PID mouse posting (revisit ADR 0004 Decision 1's rejected approach).** Killed for the same reason as in ADR 0004 — `CGEventPostToPid` against backgrounded Roblox processes is unreliable, and the serial cycle's "focus, then fire" deterministically lands events in the right window. Mouse events inherit the same trade.
- **Bound the action cap by serialized bytes instead of action count.** Considered — would let a 1000-key-only sequence through while blocking a 500-mouse-heavy one. Rejected as user-confusing; a count cap is easier to surface in the recorder UI ("450 / 500 actions") than a bytes cap ("28.4 / 30 KB").

## Open questions (for Draft → Accepted)

These must close before this ADR locks:

1. **`dt` source — wallclock or monotonic?** `ActionStreamRecorder` measures inter-event timing. Wallclock is wrong (NTP jumps mid-recording). `mach_absolute_time` / `CACurrentMediaTime()` is correct but needs to be locked explicitly. Recommend `CACurrentMediaTime()` — already used elsewhere in the cycler's loop timing.
2. **Action cap exact number.** ~500 is the working estimate. Does the user want it firmer (e.g., 480 to round under serialization-size bound) or looser (1000)? Same data-model question regardless; only the constant moves.
3. **What happens when `WindowRectTracker` reports the target window has closed mid-replay?** Three options: (a) skip the account this cycle, log it, continue with the next (matches ADR 0004 Decision 1 focus-failure recovery); (b) hard-stop the cycler; (c) reuse last-known rect and fire anyway. Recommend (a).
4. **Recorder scope — record only when Roblox is frontmost, or record everything?** If the user Cmd-Tabs to Safari mid-recording, do we capture those events too? Recommend frontmost-only (filter by target PID at capture time) — recording Safari clicks into an account's action stream is almost never what the user wants.
5. **Legacy migration write-back.** When a legacy sequence loads and migrates to `.legacy(...)`, do we write the migrated shape back to disk immediately, or keep the original bytes until the user re-records? Recommend keep-original — write-on-migrate is a surprise mutation and doesn't pay for itself.

## References

- ADR 0004 — Auto-keys cycler (this ADR retracts Decisions 2 and 5 of that ADR).
- ADR 0005 — Window layout tool (Slope D origin; D-1 introduces `WindowRectTracker`).
- ADR 0001 — Launch-time settings writers (atomic-write + DI-seam patterns this ADR mirrors).
- `~/.claude/CLAUDE.md` — hard rules reaffirmed in Decision 6.
- TinyTask — Windows freeware macro recorder, interaction-shape reference for Decision 3. No file-format interop, no shared code.
- Plan-of-record: `~/.claude/plans/plan-mac-native-woolly-pascal.md`.
