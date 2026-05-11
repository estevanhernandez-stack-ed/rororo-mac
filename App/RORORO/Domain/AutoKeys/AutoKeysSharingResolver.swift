// AutoKeysSharingResolver.swift
// Domain — pure helper that resolves which macro the cycler plays for
// a given account. After D-4.3, the resolver is library-aware:
//
//   1. account.activeMacroId  → look up in MacroStore
//        found:      .playing(macro)
//        missing:    .orphaned(macroId)
//   2. LaunchSettingsStore.defaultMacroBehavior fallback (D-3.8)
//        .skip:      .none
//        .stayAlive: .usingGlobalDefault(.stayAlive, synthSequence)
//        .useMacro:  .usingGlobalDefault(.usingMacro(macro), seq)
//        .useShared: legacy — look up macro owned by that user
//   3. (none)                  → .none (cycler skips)
//
// The resolver is the single source of truth for "what plays where."
// View-model's `buildTargets` reads `playableSequence(...)`; row badge
// reads the full `Resolution` to surface ownership in the UI.

import Foundation

public enum AutoKeysSharingResolver {

    public enum Resolution: Equatable {
        /// A macro from the library is bound to this account via
        /// `activeMacroId`. Owner attribution lives on the macro
        /// itself; the row badge inspects `macro.ownerUserId` to
        /// distinguish "my own" from "shared from X."
        case playing(Macro)
        /// Global default (D-3.8) supplied a sequence — either the
        /// synthesized stay-alive loop or a macro picked from the
        /// library via `DefaultMacroBehavior.useMacro` / `.useShared`.
        case usingGlobalDefault(reason: GlobalDefaultReason, sequence: AutoKeysSequence)
        /// activeMacroId references a macro that's no longer in the
        /// library (deleted or migration gap). UI should offer to
        /// clear the reference.
        case orphaned(macroId: String)
        /// No activeMacroId, no fallback applies. Cycler skips the
        /// account.
        case none
    }

    public enum GlobalDefaultReason: Equatable {
        /// Synthesized spacebar-after-1s sequence — no underlying macro.
        case stayAlive
        /// A specific macro from the library is the global default.
        case usingMacro(Macro)
    }

    /// Synthesized stay-alive sequence — focus → 1 s → spacebar → next.
    /// Mirrors the existing stay-awake-mode shape so both paths produce
    /// identical playback behavior.
    private static func stayAliveSequence() -> AutoKeysSequence {
        AutoKeysSequence(steps: [.spacebar(after: 1.0)])!
    }

    public static func resolve(
        account: Account,
        macros: [Macro],
        globalDefault: DefaultMacroBehavior = .skip
    ) -> Resolution {
        // 1. Explicit per-account reference (the new D-4 path).
        if let id = account.activeMacroId {
            if let macro = macros.first(where: { $0.id == id }) {
                return .playing(macro)
            }
            return .orphaned(macroId: id)
        }
        // 2. Global default fallback (D-3.8 / D-4).
        switch globalDefault {
        case .skip:
            return .none
        case .stayAlive:
            return .usingGlobalDefault(
                reason: .stayAlive,
                sequence: stayAliveSequence()
            )
        case let .useMacro(macroId):
            guard let macro = macros.first(where: { $0.id == macroId }),
                  !macro.isEmpty else {
                return .none
            }
            return .usingGlobalDefault(
                reason: .usingMacro(macro),
                sequence: macro.sequence
            )
        case let .useShared(sourceUserId):
            // Legacy D-3.8 path — translate to "the (first shared)
            // macro owned by this user." Migrated installs will have
            // re-saved as `.useMacro`; this case stays for the one
            // release the legacy shape is on disk.
            guard sourceUserId != account.userId,
                  let macro = macros.first(where: {
                      $0.ownerUserId == sourceUserId && $0.isShared && !$0.isEmpty
                  }) else {
                return .none
            }
            return .usingGlobalDefault(
                reason: .usingMacro(macro),
                sequence: macro.sequence
            )
        }
    }

    /// Convenience — returns the playable sequence for the cycler,
    /// or nil when the account is skipped. `buildTargets` uses this.
    public static func playableSequence(
        account: Account,
        macros: [Macro],
        globalDefault: DefaultMacroBehavior = .skip
    ) -> AutoKeysSequence? {
        switch resolve(account: account, macros: macros, globalDefault: globalDefault) {
        case let .playing(macro):
            return macro.isEmpty ? nil : macro.sequence
        case let .usingGlobalDefault(_, sequence):
            return sequence
        case .orphaned, .none:
            return nil
        }
    }
}
