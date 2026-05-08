# ADR 0002 — Per-account framerate cap override

**Date:** 2026-05-08
**Status:** Accepted
**Supersedes:** Partial — ADR 0001 Decision 3 said per-account divergent caps "are not achievable through this writer alone." That conclusion is updated below; the writer alone IS sufficient when launches are sequential.

## Context

ADR 0001 shipped a global FramerateCap setting via `~/Library/Roblox/GlobalBasicSettings_<N>.xml`. The user asked for per-account divergence: "main account at 60, alts at 20" rather than "everything at 20."

Re-read of the substrate: Roblox reads `GlobalBasicSettings_<N>.xml` ONCE at engine startup, not continuously. So the sequence "write XML for account A → spawn Roblox A → wait for engine startup → write XML for account B → spawn Roblox B" gives divergent caps. ADR 0001 Decision 3's conclusion ("per-account caps need a per-process throttle") was wrong about the necessity.

## Decision

Add `framerateCapOverride: Int?` to `Account`. The launcher's `applyLaunchSettings(snapshot:account:)` resolves the effective cap as `account.framerateCapOverride ?? snapshot.framerateCap`. UI surface: per-account chevron menu in `AccountsListView` gains a "Frame rate cap (this account)" section with `Use global` + `20 / 30 / 60 / 144 fps` options. Setting persists via `AccountStore.setFramerateCapOverride(userId:cap:)`.

## Consequences

**Sequential launches diverge cleanly.** User clicks Launch As account A (60fps override) → XML writes 60 → Roblox A spawns and reads 60. Several seconds later, user clicks Launch As account B (20fps override) → XML writes 20 → Roblox B spawns and reads 20. Both accounts honor their own caps; the running A is unaffected because its cap is locked in memory.

**Rapid-fire launches converge to last-write-wins.** If the user clicks Launch A then Launch B within the same engine-startup window (~1–3 seconds, varies by Mac speed), B's XML write may land before A's Roblox engine has read the file. Both end up at B's cap. Documented limitation; mitigation via a launch-serialization lock with grace period is deferred until the failure mode is observed in practice.

**Backward compatibility.** Adding an optional Codable field to `Account` is non-breaking — old `accounts.json` files decode with `framerateCapOverride = nil`. Test `testAccount_DecodesFromLegacyJsonWithoutFramerateField` locks this in.

**Out of scope for this ADR.** Per-account FFlags (graphics quality / API switch / render resolution) — A1 substrate is in but no UI yet; per-account FFlag overrides will land in a future ADR when that substrate ships its UI.

## Implementation map

| File | Change |
| --- | --- |
| `App/RORORO/Domain/Account.swift` | Add `framerateCapOverride: Int?` field |
| `App/RORORO/Domain/AccountStore.swift` | Add `setFramerateCapOverride(userId:cap:)` |
| `App/RORORO/Domain/RobloxLauncher.swift` | `applyLaunchSettings` takes `account:` and prefers override |
| `App/RORORO/UI/AccountsListView.swift` | Per-account menu section |
| `App/ROROROTests/AccountStoreTests.swift` | Persistence + Codable backward-compat tests |
