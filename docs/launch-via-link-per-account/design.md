# Launch via link, per account — design

**Date:** 2026-05-16
**Status:** Spec — pending implementation plan
**Sources:** brainstorming session 2026-05-16; references `App/RORORO/Domain/MultiInstanceCoordinator.swift`, `App/RORORO/Domain/URLSchemeHandler.swift`, `App/RORORO/Domain/RobloxLauncher.swift`.

## Context

RORORO already claims the system default handler for `roblox-player://` (`URLSchemeHandler.claim` + `restore`). When a user clicks Play on roblox.com, the browser fires the URL and macOS routes it to RORORO. The current flow lands in `MultiInstanceCoordinator.handleIncomingURL(url, userId: nil)` — `userId` is nil because the browser has no concept of which RORORO account to use. The coordinator then applies global launch settings (low-resource mode, user FFlags, the global framerate cap) and spawns Roblox. **Per-account context — cookie isolation, per-account framerate override, per-account FFlag deltas — never engage on this path.** Only the in-app "Launch As" button currently threads a userId.

This gap is the feature ask: clicking a roblox.com Play button should be able to land as a specific account, with that account's per-account settings honored.

## Decisions

Locked during the 2026-05-16 brainstorming pass:

| Decision | Choice | Why |
| --- | --- | --- |
| Direction | **Inbound** link handling only (no outbound shareable links in v1) | Scopes the ship; outbound is a separate feature deserving its own brainstorm. |
| Stickiness | **Always show picker** (no remembered default) | Most-explicit posture. Simplest scope; defer "remember last choice" to a v2 sidecar if friction warrants it. |
| Surface | **Standalone floating window** (new SwiftUI `Window` scene) | Doesn't disturb the frontmost app the user came from; doesn't require raising the main RORORO window. |
| 0 accounts | **Abort, banner** ("Add an account first") | Empty picker is hostile; the link is intentionally dropped. |
| 1 account | **Skip picker, auto-launch** | Picker with one option is friction with no value. |
| Cancel | **Abort the launch** | Window close, Esc, and Cmd-W all map to `coordinator.cancel()` → no launch fires. The user clearly didn't want it. |
| Multiple inbound URLs | **Newest wins** | If user clicks a second Play button before resolving the first, the picker re-binds to the newer URL; older URL's pending Task returns nil. Matches "I changed my mind" intent. |

## Architecture

Two new types, one branch added to `MultiInstanceCoordinator`.

### New: `LinkLaunchCoordinator` (Domain)

`@MainActor` observable. Owns the picker state machine.

**State:**
- `.idle` — nothing pending.
- `.choosing(pendingURL: URL, accounts: [Account])` — picker is open; the suspended Task is waiting on a continuation.
- `.resolved(userId: String?)` — choice submitted; `nil` indicates Cancel/abort/newest-wins-eviction.

**API:**
- `func requestChoice(url: URL, accounts: [Account]) async -> String?` — suspends the caller, transitions state to `.choosing`, returns the chosen userId on submit or `nil` on cancel/eviction.
- `func submit(userId: String)` — UI-facing; resolves the in-flight continuation with the userId.
- `func cancel()` — UI-facing; resolves the in-flight continuation with `nil`.

**Newest-wins:** if `requestChoice` is called while state is `.choosing(A)`, the in-flight continuation for A is resolved with `nil` (the suspended call unwinds without launching), state replaces to `.choosing(B)`, the picker UI rebinds to B's URL.

### New: `LinkAccountPickerWindow` (UI)

SwiftUI `Window` scene (single instance — only one picker ever exists at a time). Observes `LinkLaunchCoordinator`. Renders when state is `.choosing`; closes itself when state transitions to `.resolved`.

### Modified: `MultiInstanceCoordinator.handleIncomingURL`

New branch at the top, **only when `userId == nil`**:

```swift
if userId == nil {
    let accounts = AccountStore.shared.accounts
    switch accounts.count {
    case 0:
        MultiInstanceState.shared.lastError = "Add an account first."
        return
    case 1:
        return handleIncomingURL(url, displayLabel: displayLabel, userId: accounts[0].userId)
    default:
        Task { @MainActor in
            if let chosenUserId = await linkLaunchCoordinator.requestChoice(url: url, accounts: accounts) {
                self.handleIncomingURL(url, displayLabel: displayLabel, userId: chosenUserId)
            }
            // nil → Cancel/eviction → no launch fires
        }
        return
    }
}
// existing path continues here (userId != nil)
```

**Why recursion not a direct hand-off:** the `userId != nil` branch already does the per-account work correctly (FFlag write via `RobloxLauncher.launch`, framerate override, plist flip, cookie-isolated copy, spawn). Re-entering `handleIncomingURL` with the chosen userId reuses that path 1:1 — zero risk of drift between the picker path and the in-app "Launch As" path.

## UI

### Window scene

- `Window("Launch as…", id: "linkPicker")` — single instance.
- `windowStyle(.titleBar)` — standard close button = Cancel.
- Centered on the active screen at present time. Not resizable. Approximately 380pt wide; height scales with row count (≈ 320–460pt range for 2–8 accounts).
- Keyboard: Esc / Cmd-W / close-button all invoke `coordinator.cancel()`.

### Layout

```
┌─ Launch as… ────────────────── ✕ ┐
│                                  │
│  Opening this link with…         │  caption row (secondary text)
│  roblox-player://1?placeId=…     │  truncated URL excerpt, mono, dimmed
│                                  │
│  ┌────────────────────────────┐  │
│  │  ●  AltAcct1     active    │  clickable row (whole row hit-target)
│  │  ●  AltAcct2     running   │
│  │  ●  AltAcct3               │
│  │  ●  AltAcct4               │
│  └────────────────────────────┘  │
│                                  │
│                      [ Cancel ]  │
└──────────────────────────────────┘
```

### Interaction

- **One click per choice.** No radio-select-then-Launch. Click a row → row's `userId` submits → window closes → URL re-enters `handleIncomingURL`. Matches the macOS "Open With…" pattern.
- **State pill** on each row (active / running / idle) is informational; never disables the row. Launching a second instance of an already-running account is the user's call; `MultiInstanceState` semantics handle it downstream.
- **Cancel button** is a low-emphasis text button bottom-right. No "Don't ask again" — `Always show picker` is the agreed posture.

### Row component

New `LinkPickerAccountRow` SwiftUI view (not a reuse of the main-window account row).

**Inputs:** `Account`, `runningState` (active / running / idle), `onTap: () -> Void`.

**Why a new component (not extracting from `AccountsListView`'s row):** the existing row carries split-launch-button + chevron menu + framerate badge + macro state — way more affordance than the picker needs. Lifting it would either drag dependencies into the picker or require generalizing a working row for two-surface use. Targeted new row keeps the picker simple and the existing surface untouched.

### Visual treatment

- 626Labs design tokens via the existing `Theme` module (cyan / magenta / navy / teal). No inline color declarations.
- **No avatars in v1.** We don't currently fetch / cache avatar art; adding it pulls in network surface. Display label + state pill is sufficient.

## Edge cases

### Cold-start path

macOS launches RORORO when a `roblox-player://` arrives and we're not running. `.onOpenURL` may fire before `RororoKeychainBootstrap.ensureIfNeeded` completes and before `AccountStore` finishes loading.

**Strategy: defer at the same seam, not a new one.** `MultiInstanceCoordinator.bootIfNeeded` already gates URL handling on bootstrap completion. The new picker branch sits *after* that gate. By the time the new branch executes, accounts are loaded and the count check is meaningful. No new race surface introduced.

**Window visibility on cold-start:** if RORORO booted purely from the URL handoff, the main window stays hidden. The picker window opens regardless — it's a `Window` scene, not gated on the main window. Closing the picker does NOT raise the main window; we stay in tray-only mode if that's where we started.

### Account list changes while picker is open

User adds/removes an account from the main window while the picker is up. The picker's row list is bound to `accountStore.accounts` via observation — added accounts appear, removed accounts vanish. No frozen-snapshot trap.

### Quit while picker open

`@MainActor` coordinator state cleans up on app termination — no persistence, no recovery on next boot. URL is dropped. Matches the existing posture for any in-flight launch state.

### Already-running account

Picker shows a "running" pill on the row; the row is still clickable. If the user picks an already-running account, the existing `MultiInstanceCoordinator` path handles it (spawns the launch; multi-instance semantics decide whether a new copy is needed). Not a picker concern.

## Test plan

### Unit — `LinkLaunchCoordinatorTests`

- **State transitions:**
  - `idle → choosing → resolved(userId)` on submit.
  - `idle → choosing → resolved(nil)` on cancel.
  - `idle → choosing(A) → choosing(B) → resolved(B)` — newest-wins; older Task returns nil.
- **API contract:**
  - `requestChoice` returns the submitted userId.
  - `cancel()` resolves the in-flight continuation with `nil`.
  - Multiple concurrent `requestChoice` calls: older resolves nil, newer is the live one.

### Integration — additions to `MultiInstanceCoordinatorTests`

Inject a fake `LinkLaunchCoordinator` that returns a pre-set choice synchronously.

- `handleIncomingURL(url, userId: nil)` with **0 accounts** → no launch fired, `MultiInstanceState.lastError` populated.
- `handleIncomingURL(url, userId: nil)` with **1 account** → recurses with that userId without invoking the link coordinator at all.
- `handleIncomingURL(url, userId: nil)` with **2+ accounts** → invokes `linkLaunchCoordinator.requestChoice`, recurses with the returned userId on submit.
- Same with **2+ accounts + Cancel** → no launch fires.

### Manual smoke (out-of-scope for automated tests; documented in PR)

- **Cold-start:** quit RORORO, click a roblox.com Play button, confirm picker appears after launch completes.
- **Newest-wins:** open RORORO, click two different Play links within ~1s, confirm only one picker shows with the second link's caption.
- **Cancel paths:** window close button, Esc, Cmd-W all abort.

### Not tested in v1

- SwiftUI rendering of `LinkAccountPickerWindow` and `LinkPickerAccountRow`. Visual surfaces — manual verification only. Matches existing repo posture.
- The `LSSetDefaultHandlerForURLScheme` claim path — unchanged from existing wiring; not part of this feature.

## Files touched

**New:**
- `App/RORORO/Domain/LinkLaunchCoordinator.swift`
- `App/RORORO/UI/LinkAccountPickerWindow.swift`
- `App/RORORO/UI/LinkPickerAccountRow.swift`
- `App/ROROROTests/LinkLaunchCoordinatorTests.swift`

**Modified:**
- `App/RORORO/Domain/MultiInstanceCoordinator.swift` — new branch at the top of `handleIncomingURL`.
- `App/RORORO/App.swift` — register the new `Window` scene.
- `App/ROROROTests/MultiInstanceCoordinatorTests.swift` — integration cases for 0 / 1 / 2+ / Cancel.

## Out of scope (v1) — explicitly deferred

These are reasonable feature extensions, intentionally NOT in this ship:

- **Sticky-with-override picker mode** — remember last choice, picker only on first link. Brainstorm came down on "always show" for v1; revisit if friction emerges.
- **Default-account binding in Settings** — "Default account for browser launches: [picker]" preference. Different feature shape (zero-picker flow).
- **Outbound shareable per-account links** — RORORO generates `rororo://launch?account=X&placeId=Y` URLs. Separate brainstorm; not bundled here.
- **Avatar art in picker rows** — pulls in network + cache surface. Deferred until a separate UX iteration demands it.
- **Picker analytics / telemetry** — hard rule per project CLAUDE.md: no telemetry. Stays out forever, not just v1.

## Decision-log obligation

Per project CLAUDE.md, "URL scheme claim/restore semantics" require a logged decision. This feature touches **URL-scheme routing-after-claim**, not the claim/restore mechanics themselves — borderline. Logging the design decision (picker semantics + abort-on-Cancel posture) via `mcp__626Labs__manage_decisions log` is the right move once implementation lands. ADR file under `docs/decisions/` is not required — feature design docs live under `docs/<feature-slug>/` per repo convention.
