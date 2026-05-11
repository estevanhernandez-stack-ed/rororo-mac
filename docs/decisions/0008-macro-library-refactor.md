# ADR 0008 — Macro library refactor

**Date:** 2026-05-10
**Status:** Accepted (shipped 2026-05-10, 5 commits — `9a823d8` → `ef7cc08`)
**Slope:** D-4 (macro library)
**Reopens:** ADR 0007 Decision 7 — "Recordings scope to the account they're recorded on" — partially superseded; the ownership distinction is now an attribution tag on a first-class macro, not a permission boundary on a per-account field.

## Background

ADR 0007 (full-fidelity record-and-replay) shipped a recorder + player that stores one `AutoKeysSequence` per account, plus a cross-account `autoKeysSourceAccountId` reference for one-to-many sharing. ADR 0007 Decision 7 explicitly scoped a library of recordings as future work, with the framing: "If a library becomes useful (e.g., 'import recording from another machine'), that's a future ADR."

The future arrived within hours of shipping D-3. During the 2026-05-10 manual smoke, the user hit four friction edges in sequence:

1. **Naming the macro** — addressed in D-3.7 by adding `AutoKeysSequence.name`.
2. **Picker discoverability** — addressed in D-3.8 by surfacing the right-click sharing picker inside the V2 sheet.
3. **A stay-alive default** for unconfigured accounts — addressed in D-3.8 by adding `LaunchSettingsStore.defaultMacroBehavior` with `.skip / .stayAlive / .useShared` cases.
4. **A management view** — "where can I manage recorded macros?" — couldn't be answered cleanly under the D-3 data model. Macros lived inside accounts; there was no single surface listing them all, no way to rename without re-recording, no way to toggle share after the initial save, no way to track ownership and usage across accounts.

Item 4 forced the data-model break. Two paths were considered:

- **Minimal: a derived view.** Compute a "macros list" from `AccountStore.accounts` on the fly, render the management sheet, forward edits back to `account.autoKeys`. No real library — just a UI illusion. Avoided the migration.
- **Full: first-class macros.** Promote recordings into their own `MacroStore` with stable IDs, owner attribution, and library-level lifecycle. Accounts reference macros by id. Migration on first boot.

The user explicitly chose the full refactor over the minimal one. The minimal path would have papered over the architecture without lifting any of the underlying limits — same one-recording-per-account ceiling, same coupling of macro identity to account identity, same no-cross-machine-export story.

The hard rules from `CLAUDE.md` and ADR 0007 Decision 6 still bind. **No anti-detection. No telemetry. No injection.** The library is local storage in Application Support — nothing leaves the machine.

## Decision 1 — `Macro` becomes a first-class entity

**Decision:** Introduce a `Macro` value type with `id: String` (UUID), `name: String`, `ownerUserId: String?`, `createdAt: Date`, `variant: AutoKeysSequence.Variant`, `isShared: Bool`. Macros live in a new `MacroStore` actor (sibling to `AccountStore`) persisting to `~/Library/Application Support/RORORO/macros.json`. CRUD: `upsert / rename / setShared / delete / macro(id:) / macros(ownedBy:) / sharedMacros(excludingOwner:)`.

**Rationale:** Decoupling identity from ownership is the load-bearing move. Under D-3, a macro WAS its account — renaming was a re-record because the storage path was `account.autoKeys`; deletion was setting that field to nil. Under D-4, identity is the macro id; ownership is just an attribution tag. Renames and metadata edits are CRUD on the library, not destructive operations on the account.

**Consequences:** Two stores instead of one. The Codable shape for a Macro embeds an `AutoKeysSequence` payload, which means the D-3 stream/legacy variant split + isShared + name all serialize through the same contract — no new on-disk shape to invent. The library list view (D-4.5) becomes natural; the account-row picker becomes natural; the cycler resolver simplifies.

## Decision 2 — Account references macros by ID via `activeMacroId`

**Decision:** Add `Account.activeMacroId: String?`. The cycler's resolver reads this field, looks up the macro in `MacroStore`, and plays it. Deprecates `Account.autoKeysSourceAccountId` (cross-account reference) — sharing is now expressed as "this account's activeMacroId points at another account's macro," not as a special-cased per-account field.

**Rationale:** A single field replaces the D-3 (own recording, cross-account reference) tuple. The resolver collapses from "if reference set use source's recording else if own recording use it else …" to "lookup activeMacroId in library." Ownership is encoded on the macro, not on the resolution path.

**Consequences:** Migration translates the D-3 fields to the new shape (Decision 5). Existing on-disk data continues to load through one release for downgrade safety. Account.autoKeys + Account.autoKeysSourceAccountId stay on the type as Codable storage; production code paths never write to them again, only the migrator reads them on first boot.

## Decision 3 — Sharing is library-wide; `isShared` is the owner's hide flag

**Decision:** Any account can pick any macro in the library that has `isShared = true`. The `isShared` flag (default `true` for new macros) lives on the macro itself — toggling it off hides the macro from other accounts' pickers; the owner can still see and use it.

**Rationale:** The D-3.7 opt-in-to-share friction ("I have to remember to toggle share on at save time, or no one can use my recording") was a paper-over for the per-account model. With first-class macros, the library is the library — defaulting to shared matches the user's stated mental model from the 2026-05-10 smoke. Hiding remains an explicit choice for users with truly private recordings.

**Consequences:** Existing migrated macros inherit the shared flag from their pre-D-4 `AutoKeysSequence.isShared` value (which was opt-in, default false in D-3.7). Users who never toggled share on under D-3 will see their migrated macros default to unshared — the migrator preserves the legacy choice rather than overriding to the new default. The 2026-05-10 build's installed users see no behavior change without explicitly editing.

## Decision 4 — `DefaultMacroBehavior` grows a `.useMacro(macroId:)` case

**Decision:** The D-3.8 global-default-macro setting (`LaunchSettingsStore.defaultMacroBehavior`) gains a `.useMacro(macroId: String)` case alongside the existing `.skip / .stayAlive / .useShared(sourceUserId:)`. The toolbar picker writes the new case going forward; `.useShared` is decoded and honored for one release for downgrade safety.

**Rationale:** With macros as first-class entities, the global default should point at a stable macro id, not at a user id (which means "look up the first shared macro owned by that user" — fragile to ownership changes). The library refactor makes the cleaner reference natural.

**Consequences:** UserDefaults values from the D-3.8 shipped release continue working — the resolver translates `.useShared(sourceUserId:)` to "first shared macro owned by this user." The next time the user opens the toolbar picker and re-selects their default, the value re-emits as `.useMacro`. Eventual D-5 or later cleanup can remove the legacy case after a deprecation window.

## Decision 5 — Migration translates D-3 state on first boot

**Decision:** `AutoKeysLibraryMigrator` is a pure helper (`migrate(accounts:existingMacros:)` → `Outcome(updatedAccounts:createdMacros:)`) invoked from `App.swift`'s `.onAppear` via `AccountStore.shared.migrateAutoKeysToLibrary(via: MacroStore.shared)`. Translation rules:

  1. `account.autoKeys != nil` → new `Macro` with this account as owner. Sequence name (D-3.7), variant, and isShared inherited. Account's `activeMacroId` set to the new macro id. In-memory `autoKeys` cleared.
  2. `account.autoKeysSourceAccountId != nil` (and no own autoKeys) → activeMacroId points at the source's migrated macro (pass 2 looks up by owner). Broken reference (source missing) → activeMacroId stays nil.
  3. Account already migrated (activeMacroId set + macro exists) → pass-through unchanged.

**Idempotency:** Two passes produce identical output. The "already migrated" case in pass 1 prevents double-creation.

**On-disk shape:** In-memory account state mutates immediately on migration; the on-disk `accounts.json` shape catches up on next `AccountStore.save()`. Matches ADR 0007 Decision 4's byte-stable posture — legacy bytes stay readable until the next mutation.

**Rationale:** Idempotent + pure migration is testable in isolation (7 dedicated tests). Running on `.onAppear` rather than `AccountStore.init` keeps the store free of cross-singleton coupling for tests. The "already migrated" early-exit makes second-boot a no-op without dirtying the save.

**Consequences:** First-boot users on the D-4 release see migration complete before the toolbar renders. Downgrade safety: if the user reverts to the pre-D-4 build, accounts.json's legacy autoKeys + autoKeysSourceAccountId fields are still on disk (we cleared in-memory only). Macros.json is just ignored by the old code. One-way break only happens after the user mutates an account post-migration — then the new accounts.json shape (no autoKeys, activeMacroId set) wouldn't roundtrip cleanly to the old code.

## Decision 6 — Resolver simplifies to a 4-case Resolution

**Decision:** `AutoKeysSharingResolver.Resolution` becomes:

```swift
enum Resolution {
  case playing(Macro)
  case usingGlobalDefault(reason: GlobalDefaultReason, sequence: AutoKeysSequence)
  case orphaned(macroId: String)
  case none
}
enum GlobalDefaultReason {
  case stayAlive
  case usingMacro(Macro)
}
```

Resolution order: `activeMacroId` lookup → global default fallback → `.none`. Ownership distinction (own macro vs borrowed macro) moves to the badge layer, which inspects `macro.ownerUserId` to label.

**Rationale:** Down from 6 cases (ownRecording / sharedFrom / ownEmpty / orphaned / sourceNotShared / usingGlobalDefault) to 4. The `.sourceNotShared` case dissolves because library-wide sharing replaces account-tied sharing — a macro is either in the library and pickable, or it isn't. Cases that distinguished resolver-side ownership become Macro-side attribution that the UI surfaces however it wants.

**Consequences:** All callers update. AutoKeysCyclerViewModel passes `MacroStore.shared.macros` to `playableSequence`. AutoKeysRowBadge renders the 4-case switch with `macro.ownerUserId == account.userId` branches inside the `.playing` case.

## Decision 7 — Macro library management lives in a single sheet

**Decision:** `MacroLibrarySheet` (toolbar chevron → "Macros…") is the single management surface. Lists every macro with inline rename (pencil icon → TextField), share toggle (per-row Switch), and delete (trash → confirmation alert → cascade). Subtitle on each row shows owner display name + usage count ("from Alice · used by 2 accounts"). Empty state guides the user back to the per-row recording chip.

**Rationale:** Single surface beats two surfaces (per-account chip context menu + separate library view) for the management use case. The chip's right-click menu still works — it's the fast path for binding an account to a different macro. The library sheet is for renaming, deleting, and seeing what exists.

**Consequences:** Out of scope for v1: drag-to-reorder, import/export, history of past versions, sequence-level editing (steps within a macro). Re-record remains the path to update a macro's actions; library edits cover metadata only.

## Approaches considered and rejected

- **Minimal derived view (no migration).** Killed by Decision 1 — the user explicitly chose the full refactor when offered both. The derived view would have left the underlying coupling (macro identity = account identity) in place, blocking future features like cross-machine export.
- **Macros embedded in `accounts.json` as an array per account.** Killed by Decision 2's reference-by-id model. Multiple accounts referencing the same macro id can't easily share storage; a separate macros.json with id-based references is cleaner.
- **Hard-delete `Account.autoKeys` + `autoKeysSourceAccountId` in this release.** Killed by Decision 5's downgrade-safety posture. The fields stay one release; D-5 (or later) can remove them once the user base is past the migration cliff.
- **Auto-migration on every load (not just first boot).** Killed by Decision 5's idempotency — a `migrateAutoKeysToLibrary` call is cheap when there's nothing to migrate, but running it on every save creates a feedback loop (save → migrator runs → save → ...). Calling once at app boot avoids the loop.
- **Library-level versioning of macros (record v1, v2, v3 per macro id).** Killed for v1 scope. Re-record overwrites the user's own active macro; if they had someone else's macro selected, a fresh library entry is created. Versioning is a future ADR if friction surfaces.

## Testing

- **Unit:**
  - `Macro` — name normalization (trim, fallback for empty), Codable round-trip (id + ownerUserId + createdAt + variant + isShared all preserved).
  - `MacroStore` — CRUD (upsert / rename / setShared / delete), sharedMacros filter (with and without owner exclusion), persistence across reload.
  - `AutoKeysLibraryMigrator` — all 4 translation cases (own / sharing ref / orphaned ref / nothing), legacy variant promotion, idempotency on second pass.
  - `AutoKeysSharingResolver` — all 4 Resolution cases (playing / usingGlobalDefault / orphaned / none), all 4 DefaultMacroBehavior cases (.skip / .stayAlive / .useMacro / .useShared legacy), playableSequence convenience including empty-macro skip.
- **Manual test plan:**
  1. Fresh install (no existing accounts.json) → library empty → record a macro → appears in library → management sheet shows it.
  2. Existing install with D-3 recordings → first boot runs migrator → library populated with migrated macros → row badges flip from "N ACTS · Ts" / "USING X" to library-driven labels → playback works unchanged.
  3. Existing install with D-3 cross-account sharing reference → consumer account's activeMacroId points at owner's migrated macro → playback works unchanged.
  4. Rename a macro in the management sheet → badge on owner's row updates → consumer accounts using the macro still play it (id stable).
  5. Delete a macro in the management sheet → confirmation alert → cascade clears activeMacroId on any account using it → those accounts fall back to global default or skip.
  6. Toggle share off on a macro → other accounts' pickers stop showing it → owner still sees + uses it.
  7. Toolbar "Default for unrecorded accounts" → list shows library macros (not accounts) → picking writes `.useMacro(macroId:)` to UserDefaults → resolver picks it up.

## References

- ADR 0007 — Full-fidelity record-and-replay (the model this ADR partially supersedes; Decision 7 retracted in part).
- ADR 0004 — Auto-keys cycler (still load-bearing for the legacy step-list cycler path).
- `docs/user/auto-keys-recording.md` — user-facing operating instructions (updated for D-4 in this slope).
- 2026-05-10 manual smoke session — surfaced naming, picker discoverability, stay-alive default, and management view in sequence; informed the D-3.7 / D-3.8 / D-4 trajectory.
