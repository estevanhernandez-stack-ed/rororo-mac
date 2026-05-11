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

## Sharing a recording across accounts

If multiple accounts should run the same sequence (e.g., jump-spam, identical farming loop), record it once and share:

1. On the *owner* account's row, record your sequence as above.
2. In the recorder sheet's post-record review, toggle **Share this recording** on, then Save.
3. On any *consumer* account's row, **right-click** the auto-keys chip → **Use shared recording** → pick the owner. The consumer's chip updates to show `USING [Owner]`.
4. Press Play. Both accounts now run the same recording against their own Roblox windows. Window-relative coords mean the mouse clicks land correctly even if the windows are at different positions or sizes.

**Reverting to own recording:** right-click the chip on the consumer → **Use my own recording**.

**If the source goes away:** the badge shows `SHARED · MISSING` in a warning color. Right-click → either clear the reference or pick a new source.

## Legacy recordings

If you set up auto-keys before D-3 (the action-stream slope), your row's chip shows `LEGACY · N KEYS`. The cycler still runs those recordings unchanged — you don't have to do anything. But you can no longer edit them in place. To replace one with a full action-stream recording (with mouse support), click the chip → record → Save. The new recording overwrites the legacy one.

## Hard rules

- **No anti-detection.** RORORO posts CGEvents through the same public APIs any accessibility tool uses. We don't inject, patch, or evade. The cycler steals focus before firing — every keystroke + click lands in the frontmost Roblox window, which is the one we just focused.
- **No telemetry.** Recordings live on this Mac, never sent anywhere.
- **No mouse-coordinate magic.** Window-relative coords (top-left origin) translate to absolute screen coords at replay time via the live AX window rect. If you resize a Roblox window way down, clicks recorded against the original size may land out of bounds — they're clamped to the current rect, but UI elements that were inside the old window might not be inside the new one.

## Where things live (for the curious)

- The recorder UI: `App/RORORO/UI/AutoKeysRecorderV2Sheet.swift`
- The capture engine: `App/RORORO/Domain/AutoKeys/ActionStreamRecorder.swift`
- The replay engine: `App/RORORO/Domain/AutoKeys/ActionStreamPlayer.swift`
- The cycler: `App/RORORO/Domain/AutoKeys/AutoKeysCycler.swift`
- Sharing resolution: `App/RORORO/Domain/AutoKeys/AutoKeysSharingResolver.swift`
- Specs: `docs/decisions/0007-full-fidelity-record-and-replay.md` (canonical) + `docs/decisions/0004-auto-keys-cycler.md` (original ADR, amended)
