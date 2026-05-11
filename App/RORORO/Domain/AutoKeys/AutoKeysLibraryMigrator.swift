// AutoKeysLibraryMigrator.swift
// Domain — pure helper that translates the D-3 per-account recording
// model (`Account.autoKeys` + `Account.autoKeysSourceAccountId`) into
// the D-4 first-class macro library model (`MacroStore` + `Account
// .activeMacroId`).
//
// Migration is idempotent — running it twice on the same input
// produces the same output. Accounts already migrated (no `autoKeys`,
// no `autoKeysSourceAccountId`, possibly `activeMacroId` set) pass
// through unchanged. Accounts with one of the legacy fields set
// produce a Macro in `createdMacros` and an updated Account with
// `activeMacroId` set.
//
// **Translation rules:**
//   1. `account.autoKeys != nil` → create a Macro with this account
//      as owner. Name from `autoKeys.name` (D-3.7) or fallback. Set
//      `account.activeMacroId = macro.id`. Clear `account.autoKeys`
//      in the in-memory account; on-disk legacy bytes stay until
//      next save (matches ADR 0007 Decision 4 posture).
//   2. `account.autoKeysSourceAccountId != nil` (and no own autoKeys)
//      → find the source account's *migrated* macro (which we just
//      created in step 1) and set `activeMacroId` to that. If the
//      source isn't found, leave `activeMacroId` nil (cycler skips).
//      Clear `autoKeysSourceAccountId`.
//
// Pure function — testable without disk / actor isolation.

import Foundation

public enum AutoKeysLibraryMigrator {

    public struct Outcome: Equatable {
        public let updatedAccounts: [Account]
        public let createdMacros: [Macro]
    }

    public static func migrate(
        accounts: [Account],
        existingMacros: [Macro]
    ) -> Outcome {
        // Pass 1: for every account with a non-nil autoKeys, create a
        // Macro. Build a map `ownerUserId → newMacroId` so pass 2 can
        // translate sharing references into activeMacroId values.
        var createdMacros: [Macro] = []
        var newMacroByOwner: [String: String] = [:]
        for account in accounts {
            guard let seq = account.autoKeys, !seq.isEmpty else { continue }
            // Skip if this account already has an activeMacroId pointing
            // at an existing macro — second-run idempotency.
            if let existingId = account.activeMacroId,
               existingMacros.contains(where: { $0.id == existingId }) {
                continue
            }
            let macro = Macro(
                name: seq.name ?? "",
                ownerUserId: account.userId,
                variant: seq.variant,
                isShared: seq.isShared
            )
            createdMacros.append(macro)
            newMacroByOwner[account.userId] = macro.id
        }

        // Pass 2: walk accounts again and produce updated Account values.
        let updatedAccounts: [Account] = accounts.map { account in
            var updated = account
            // Resolve activeMacroId.
            if account.activeMacroId == nil {
                if let ownNewId = newMacroByOwner[account.userId] {
                    updated.activeMacroId = ownNewId
                } else if let sourceId = account.autoKeysSourceAccountId,
                          let sourceMacroId = newMacroByOwner[sourceId] {
                    updated.activeMacroId = sourceMacroId
                }
                // Else: leave nil — orphaned reference or no recording.
            }
            // Clear legacy fields in-memory. On-disk shape stays byte-
            // stable until the next AccountStore save.
            updated.autoKeys = nil
            updated.autoKeysSourceAccountId = nil
            return updated
        }

        return Outcome(
            updatedAccounts: updatedAccounts,
            createdMacros: createdMacros
        )
    }
}
