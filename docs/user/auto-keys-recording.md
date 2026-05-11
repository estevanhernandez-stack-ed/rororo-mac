# Auto-keys: recording and replaying a session

RORORO's auto-keys feature keeps multiple Roblox accounts alive by walking through each window in turn, focusing it, and replaying whatever keyboard + mouse sequence you've recorded for that account. This doc covers the day-to-day flow.

## What you can record

A **session recording** is a full-fidelity capture of:

- Keyboard presses (with modifiers — Shift, Control, Option, Command).
- Mouse moves, left-clicks, right-clicks — all with window-relative positions so moving the Roblox window between record and replay doesn't break the recording.
- The timing between every action — replayed verbatim by the cycler.

Cap: **500 actions per recording**. At typical density that's roughly 30–60 seconds of dense in-game input.

## How to record

1. **Configure the account.** Add the Roblox account to RORORO (cookie + login) and launch a Roblox window for it. The cycler only records / replays against accounts that have a running Roblox process.
2. **Open the recorder.** On the account's row, click the **AUTO-KEYS** chip (or any of the variant labels that show up after you have a recording). The V2 recorder sheet opens.
3. **Note your record hotkey.** The sheet shows your current chord at the top — default is **⌃⌥⇧P** (Control + Option + Shift + P). This is the global hotkey that starts and stops the actual capture. You can rebind it with the **Change** button (bare keys with no modifiers are rejected — the chord must include at least one modifier).
4. **Click Record.** The recorder is now *armed* — the event source is live but no actions are being captured yet. The sheet says "Armed — press chord in Roblox to start."
5. **Cmd-Tab to your Roblox window.** Cmd-Tab keystrokes happen while the recorder is still armed, so they get dropped. The sheet flips to "Paused (Roblox not frontmost)" — that's expected and means the frontmost-gate is working.
6. **Press ⌃⌥⇧P** (or your custom chord). The recorder transitions to *active*. The chord itself is filtered from the captured stream so it never replays.
7. **Do the thing.** Move, jump, click, attack — whatever you want the cycler to repeat on this account. Watch your action count climb in your peripheral vision; the cap banner trips at 500.
8. **Press the chord again.** The recorder transitions to *stopped*. From here you can Cmd-Tab back to RORORO without contaminating the recording.
9. **Save.** Click **Save** in the sheet. The recording attaches to the account; the row's chip updates to show `N ACTS · Ts`.

If you mess up: click **Re-record** instead of Save. The previous capture is discarded and you go back to step 4.

## How to replay

1. Make sure all the Roblox windows you want to cycle are running (launch them from RORORO).
2. In the toolbar at the top of the RORORO window, click **Play** on the cycler.
3. The cycler focuses each account's window in turn, replays that account's recording, then moves to the next. Loop delay between full passes is configurable in the toolbar.

The toolbar shows: which account is currently being driven, which is next, the elapsed run time, and a countdown to the next iteration.

### Pausing and stopping

- **Click anywhere outside RORORO and the Roblox windows** (e.g., Safari, Mail, Finder) → cycler pauses with the reason "focus stolen." Press Play in the toolbar to resume.
- **Engage with the cursor outside any tracked Roblox window** → cycler pauses briefly (1.5s auto-resume). Engagement inside a tracked Roblox window doesn't pause — you can interact with the game while the cycler waits its turn.
- **Hit the toolbar Stop button** → full stop, releases the wake-lock.
- **Use your kill-key gesture** (configured in the Auto-keys safety setup) → also stops, with the same effect as the toolbar button. *Note: this path has had reliability issues; if the kill key doesn't fire, fall back to the toolbar Stop button or click on another app.*

## The macro library

As of D-4 (May 2026), recordings are first-class **macros** that live in a shared library, not per-account fields. Every macro has a stable id, an owner attribution, and a shared flag — any account can be bound to any shared macro, and any macro can be renamed / shared / deleted without re-recording.

**The library lives at** `~/Library/Application Support/RORORO/macros.json`. The toolbar's cycler chevron menu has a **Macros…** entry that opens the management view: every macro across every account in one list, with inline rename (pencil icon), share toggle, and delete (with confirmation that warns which accounts will fall back to the global default).

If you used RORORO before D-4 shipped, your existing recordings migrated automatically on first boot — every account's recording became a Macro with that account as owner, and any cross-account sharing reference translated to a direct macro reference. No re-recording needed.

## Sharing a recording across accounts

If multiple accounts should run the same macro (e.g., jump-spam, identical farming loop), record it once and bind multiple accounts to it:

1. On account A's row, record your sequence. In the post-record review, leave **Share this recording** on (the default) and Save. The macro lands in the library.
2. On account B's row, **right-click** the auto-keys chip → **Use macro** → pick A's recording from the submenu. The consumer's chip updates to show `A · MACRO NAME`. The picker also appears as the **ACTIVE MACRO** section inside the V2 sheet (left-click) for discoverability.
3. Press Play. Both accounts now run the same macro against their own Roblox windows. Window-relative coords mean the mouse clicks land correctly even if the windows are at different positions or sizes.

**Switching macros:** right-click the chip → **Use macro** picks a different one, **Use my recording** lists this account's own macros, **Clear active macro** unbinds.

**If a macro is deleted from the library:** any account bound to it falls back to the global default (or skip if none configured). The badge shows `MACRO · MISSING` in a warning color until you pick a new one or clear the reference.

**Toggling share off:** in the management view, flip the per-row Switch to hide a macro from other accounts' pickers. The owner can still see and use it.

## Default for unrecorded accounts

The cycler toolbar's chevron menu has a **Default for unrecorded accounts** submenu. Three options:

- **Skip (do nothing)** — current behavior, accounts without an active macro are skipped on each cycle.
- **Stay alive (spacebar)** — built-in synthesis: focus → 1 s → spacebar → next iteration. Identical playback to the existing stay-awake-mode toggle, but as a fallback for unconfigured accounts only.
- **Use [Account] / [Macro Name]** — one entry per shared macro in the library. Any account without an active macro plays this one.

**Custom recordings + explicit macro selections still win over the default.** The default is the bottom of a four-tier waterfall:

1. account.activeMacroId → look up in library
2. global default (this setting)
3. (none — cycler skips)

This is distinct from the **Stay-awake mode** toggle, which is a global *override* (every running account gets synthesized spacebar regardless of recordings). Stay-awake wins when both are on.

## Legacy recordings

If you set up auto-keys before D-3 (the action-stream slope), your row's chip shows `LEGACY · N KEYS`. The cycler still runs those recordings unchanged — you don't have to do anything. But you can no longer edit them in place. To replace one with a full action-stream recording (with mouse support), click the chip → record → Save. The new recording overwrites the legacy one.

## Hard rules

- **No anti-detection.** RORORO posts CGEvents through the same public APIs any accessibility tool uses. We don't inject, patch, or evade. The cycler steals focus before firing — every keystroke + click lands in the frontmost Roblox window, which is the one we just focused.
- **No telemetry.** Recordings live on this Mac, never sent anywhere.
- **No mouse-coordinate magic.** Window-relative coords (top-left origin) translate to absolute screen coords at replay time via the live AX window rect. If you resize a Roblox window way down, clicks recorded against the original size may land out of bounds — they're clamped to the current rect, but UI elements that were inside the old window might not be inside the new one.

## Where things live (for the curious)

- The recorder UI: `App/RORORO/UI/AutoKeysRecorderV2Sheet.swift`
- The library management view: `App/RORORO/UI/MacroLibrarySheet.swift`
- The macro entity + store: `App/RORORO/Domain/AutoKeys/Macro.swift` + `MacroStore.swift`
- The capture engine: `App/RORORO/Domain/AutoKeys/ActionStreamRecorder.swift`
- The replay engine: `App/RORORO/Domain/AutoKeys/ActionStreamPlayer.swift`
- The cycler: `App/RORORO/Domain/AutoKeys/AutoKeysCycler.swift`
- Sharing resolution (library-aware): `App/RORORO/Domain/AutoKeys/AutoKeysSharingResolver.swift`
- D-3 → D-4 migration: `App/RORORO/Domain/AutoKeys/AutoKeysLibraryMigrator.swift`
- Specs: `docs/decisions/0008-macro-library-refactor.md` (current canonical) + `docs/decisions/0007-full-fidelity-record-and-replay.md` (recorder/player layer) + `docs/decisions/0004-auto-keys-cycler.md` (cycler foundation, amended for both slopes)
