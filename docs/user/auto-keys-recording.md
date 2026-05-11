# Auto-keys: recording, library, and replay

RORORO's auto-keys feature keeps multiple Roblox accounts alive by walking through each window in turn, focusing it, and replaying a macro of keys + mouse input you recorded. This is the day-to-day operating guide.

---

## The model in 30 seconds

- **Macro** — a recorded sequence of keyboard + mouse actions. Has a name, an owner (the account that recorded it), and a shared flag. Replays verbatim, with mouse positions adjusted for window placement.
- **Library** — every macro you've recorded across every account lives in one place (`~/Library/Application Support/RORORO/macros.json`). The toolbar's chevron menu → **Macros…** opens the management view.
- **Active macro** — what the cycler plays for a given account. Each account has one, or none. An account's active macro can be its own recording, OR any other account's shared macro.
- **Default macro** — fallback for accounts with no active macro. Three options (set in the toolbar): skip, stay alive (synthesized spacebar), or "use [some library macro]."
- **Cycler** — the loop that focuses each Roblox window in turn and plays its active macro. Toolbar Play / Stop.

That's it. Everything below is detail.

---

## First-time setup: record a macro

You need a Roblox account configured in RORORO and a Roblox window running for it.

1. **Open the recorder.** Click the auto-keys chip on the account's row (label is `AUTO-KEYS` if you haven't recorded yet). The recorder sheet opens.

2. **Note your record hotkey.** The sheet shows the current chord at the top — default is **⌃⌥⇧P** (Control + Option + Shift + P). This is a global hotkey that starts and stops the actual capture, so you can stay focused on the Roblox window without Cmd-Tabbing back to click buttons. Change it via the **Change** button if you want; bare keys without a modifier are rejected.

3. **Click Record.** The recorder is now *armed*. The event source is live but nothing is being captured yet — the status block says "Armed — press chord in Roblox to start."

4. **Cmd-Tab to your Roblox window.** Cmd-Tab keystrokes happen while the recorder is still armed, so they get dropped (along with anything else you press while not in Roblox). The status block flips to "Paused (Roblox not frontmost)" — expected. The frontmost-gate is working.

5. **Press ⌃⌥⇧P inside Roblox.** Capture goes live. The chord keystroke itself is filtered from the captured stream, so it never replays.

6. **Do the thing.** Move, jump, click, attack, charge — whatever you want the cycler to repeat on this account. Action count climbs in the sheet (you can glance over via Mission Control). Cap is 500 actions; a banner trips if you hit it.

7. **Press ⌃⌥⇧P again.** Capture stops. Now you can Cmd-Tab back to RORORO without contaminating the recording.

8. **Name + save.** Back in the recorder sheet, optionally type a name in the **NAME** field ("Combat rotation", "Farming loop", whatever). Decide whether to keep **Share this recording** on (default — let other accounts use this macro) or turn it off. Click **Save**.

The macro lands in the library. The account's chip flips to show the macro name in uppercase.

---

## Using a macro on multiple accounts

Once a macro is in the library, any account can play it. Two paths:

**Right-click the auto-keys chip** on any other account's row → **Use macro** → pick the macro from the submenu. The picker shows `Owner · Macro Name` for each shareable entry. The chip on the consumer's row updates to show `OWNER · MACRO NAME` (subtle visual difference: a `person.2.fill` icon instead of `keyboard.fill`).

**Or, from the recorder sheet's ACTIVE MACRO picker** (left-click the chip → sheet opens with a picker section at top). Same options, plus "My macros" (this account's own library entries) and "No macro (cycler skips this account)."

Press Play on the cycler toolbar. Both accounts now run the same macro against their own Roblox windows. Mouse positions are window-relative, so clicks land in the right spots even if the windows are at different positions or sizes.

**To switch a macro elsewhere:** same picker; pick something different.

**To revert to own recording:** right-click → **Use my recording** → pick one of this account's own macros.

**To unbind entirely:** right-click → **Clear active macro**. The cycler will skip this account unless the global default applies (see next section).

---

## Default for unrecorded accounts

What should happen for an account with no active macro? Three choices, set in the cycler toolbar's chevron menu → **Default for unrecorded accounts**:

- **Skip (do nothing)** — the cycler walks past this account on each iteration. This is the default.
- **Stay alive (spacebar)** — built-in synthesis. Focus the window, wait 1 second, press spacebar, move on. Keeps the account from AFK-timing-out without you having to record anything.
- **Use [Account] / [Macro Name]** — one entry per shared macro in the library. Every account without its own active macro plays this one.

The toolbar's existing **Stay-awake mode** toggle is a different thing — that's a global *override* (every running account plays synthesized spacebar regardless of any recordings). Stay-awake wins when both are configured.

The resolver waterfall, in priority order:

1. Stay-awake mode ON → synthesized spacebar everywhere. Skip the rest.
2. Account has an active macro → play that.
3. Default is set (stay alive / use macro) → play the default.
4. Otherwise → skip the account this cycle.

---

## The macro library (managing what you have)

Toolbar chevron menu → **Macros…** opens the library sheet. Every macro across every account, in one list.

Each row shows:
- **Name** (click the pencil icon to rename inline; Enter commits).
- **Owner + usage** — "from Alice · used by 2 accounts" or "from Bob · unused."
- **Action count + duration** — e.g. `42 ACTS · 3.2S` or `1 STEPS · 6.0S` (legacy).
- **Share toggle** — flip off to hide this macro from other accounts' pickers. The owner can still see and use it.
- **Trash icon** — opens a confirmation alert. Deleting cascades: any account currently bound to this macro loses its `activeMacroId` and falls back to the global default (or skip).

The library is the only place to rename, toggle sharing without re-recording, or see usage at a glance.

---

## Playing the cycler

1. Make sure all the Roblox windows you want to cycle are running (launch each from the per-row Launch As button).
2. In the toolbar at the top of the RORORO window, click **Play**.
3. The cycler focuses each account's window in turn, plays its active macro (or the global default), then moves to the next. Loop delay between full passes is configurable in the toolbar's "Cycle pace" submenu.

The toolbar status surfaces: which account is currently being driven, which is next, the elapsed run time, and a countdown to the next iteration.

### Pausing

- **Click on another app** (Safari, Mail, Finder, anywhere outside RORORO and the Roblox windows) → cycler pauses with the reason "focus stolen." Press Play in the toolbar to resume.
- **Engage with the cursor outside any tracked Roblox window** (mouse movement near the menu bar, etc.) → cycler pauses briefly (1.5s auto-resume). Engagement inside a tracked Roblox window doesn't pause — you can interact with the game while the cycler waits its turn.

### Stopping

- **Toolbar Stop button** — full stop. Releases the system wake-lock. Reliable.
- **Kill-key gesture** (configured in Auto-keys safety setup) — same effect. *Currently unreliable; if it doesn't fire, fall back to the toolbar button or click another app to pause.*

---

## Chip state reference

The auto-keys chip on each account row tells you what the cycler will play for that account. Quick-scan reference:

| Chip label | Meaning |
|---|---|
| `AUTO-KEYS` | No active macro. Cycler skips (unless global default applies). |
| `MACRO NAME` (uppercase, this account's macro) | Own macro is active. |
| `OWNER · MACRO NAME` | Bound to another account's shared macro. |
| `LEGACY · N KEYS` | Pre-D-3 step-list recording. Still runs but can't be edited — re-record to upgrade. |
| `DEFAULT · STAY ALIVE` | No active macro; global default is "stay alive" (synthesized spacebar). |
| `DEFAULT · OWNER/MACRO` | No active macro; global default is a specific shared macro. |
| `MACRO · MISSING` | Active macro reference is broken (macro was deleted). Right-click to clear or pick another. |

Hover the chip for a longer help text that explains the state.

---

## Editing a recording

You can't edit the actions inside a macro — re-recording is the path. Click the chip on the row, click Record, repeat the capture flow. On Save:

- If the active macro is one you own → the new recording **replaces** it (same library id; bound consumers keep playing it under the same id).
- If the active macro is someone else's (you've bound this account to a borrowed macro) → the new recording creates a **fresh** entry in the library with you as the owner. The borrowed macro is untouched.

Metadata edits (rename, toggle share, delete) happen in the library sheet without re-recording.

---

## Legacy recordings

If you set up auto-keys before May 2026 (the D-3 / D-4 slopes), your recordings were per-account step lists. They migrated to library macros automatically on first boot — every account that had its own recording now has an active macro in the library, and any cross-account sharing reference translated to a direct macro binding. No re-recording needed; they still run.

But the legacy variant only supports keyboard with fixed delays — no mouse, no overlap, no modifier capture. The chip shows `LEGACY · N KEYS` and re-recording promotes it to the new action-stream variant. (The original step-list editor was removed in D-3.6; the V2 recorder is the only path to create or update macros now.)

---

## Hard rules

- **No anti-detection.** RORORO posts CGEvents through the same public APIs any accessibility tool uses. We don't inject, patch, or evade. The cycler steals focus before firing — every keystroke + click lands in the frontmost Roblox window, which is the one we just focused.
- **No telemetry.** Macros live on this Mac. Nothing leaves the machine.
- **No mouse-coordinate magic.** Window-relative coords (top-left origin) translate to absolute screen coords at replay time via the live AX window rect. If you resize a Roblox window way down, clicks recorded against the original size may land out of bounds — they're clamped to the current rect, but UI elements that were inside the old window might not be inside the new one.

---

## Troubleshooting

**The cycler pauses immediately when it focuses my second window.**
Fixed in commit `83e7cc3` (May 2026). If you're on a build before that, update.

**My kill-key gesture isn't stopping the cycler.**
Known issue. Use the toolbar Stop button or click outside Roblox to pause. The kill-key path needs a diagnostic pass.

**My chip shows `MACRO · MISSING` and won't clear.**
Right-click → **Clear active macro**. The reference was pointing at a macro that's been deleted from the library; clearing it returns the account to "no macro" (or the global default fires, if set).

**Cmd-Tab events ended up in my recording.**
You're on a build before D-3.4.1. Update — the hotkey-driven start/stop pattern filters them.

**Roblox window moved between record and replay; clicks land in the wrong place.**
Open the recorder, re-record. Window-relative coords survive small moves but not full re-layouts.

**The "Use macro" picker is empty even though I have macros.**
The picker shows macros owned by OTHER accounts with `isShared = true`. Your own macros are under "Use my recording." If you turned share off in the library view, other accounts can't see your macro.

---

## Where things live (for the curious)

- The recorder UI: `App/RORORO/UI/AutoKeysRecorderV2Sheet.swift`
- The library management view: `App/RORORO/UI/MacroLibrarySheet.swift`
- The macro entity + store: `App/RORORO/Domain/AutoKeys/Macro.swift` + `MacroStore.swift`
- The capture engine: `App/RORORO/Domain/AutoKeys/ActionStreamRecorder.swift`
- The replay engine: `App/RORORO/Domain/AutoKeys/ActionStreamPlayer.swift`
- The cycler: `App/RORORO/Domain/AutoKeys/AutoKeysCycler.swift`
- Sharing resolution (library-aware): `App/RORORO/Domain/AutoKeys/AutoKeysSharingResolver.swift`
- D-3 → D-4 migration: `App/RORORO/Domain/AutoKeys/AutoKeysLibraryMigrator.swift`
- Specs: `docs/decisions/0008-macro-library-refactor.md` (current canonical) + `docs/decisions/0007-full-fidelity-record-and-replay.md` (recorder/player) + `docs/decisions/0004-auto-keys-cycler.md` (cycler foundation, amended)
