// AutoKeysSharingResolver.swift
// Domain — pure helper that resolves an account's effective auto-keys
// sequence through the ADR 0007 Decision 7 sharing reference.
//
// Inputs:
//   - The consumer account (the one we want to play actions for).
//   - The full account list (to look up the source by id when the
//     consumer has set `autoKeysSourceAccountId`).
//
// Output: a `Resolution` describing the chosen sequence — or why no
// sequence was chosen (orphaned reference, source not shared, etc).
//
// Why pure: the cycler itself doesn't know about accounts (its Target
// type carries only pid + sequence + label). Sharing resolution belongs
// at the view-model layer where account context lives; this helper
// keeps the policy in one place so it's testable in isolation and
// reusable across surfaces (the future recorder UI badge will use the
// same logic to surface "consuming X's recording" without re-deriving).

import Foundation

public enum AutoKeysSharingResolver {

    public enum Resolution: Equatable {
        /// Account has no sharing reference and plays its own non-empty
        /// recording. The carried sequence is what the cycler should use.
        case ownRecording(AutoKeysSequence)
        /// Account references another account's shared recording. Carries
        /// the source's id (for UI breadcrumbs) and the chosen sequence.
        case sharedFrom(sourceAccountId: Account.ID, sequence: AutoKeysSequence)
        /// Account has no reference, no own recording, and the global
        /// default kicked in (D-3.8). `reason` distinguishes the
        /// synthesized stay-alive case from the shared-account case.
        case usingGlobalDefault(reason: GlobalDefaultReason, sequence: AutoKeysSequence)
        /// Account has no reference and no own recording — cycler skips it.
        case ownEmpty
        /// Account references a source that no longer exists (deleted
        /// account) or whose `autoKeys` is nil/empty. Cycler skips it.
        case orphaned(missingSourceAccountId: Account.ID)
        /// Account references an existing source whose recording is NOT
        /// marked `isShared`. Cycler skips it and the UI should offer to
        /// clear the broken reference (D-3.5).
        case sourceNotShared(sourceAccountId: Account.ID)
    }

    public enum GlobalDefaultReason: Equatable {
        /// Synthesized spacebar-after-N-seconds sequence (no source
        /// account — built inline by the resolver).
        case stayAlive
        /// Sourced from another account's shared recording.
        case sharedFrom(sourceAccountId: Account.ID)
    }

    /// Synthesized stay-alive sequence — focus → 1 s → spacebar → next.
    /// Matches the existing stay-awake-mode shape so both paths produce
    /// identical playback behavior.
    private static func stayAliveSequence() -> AutoKeysSequence {
        // Force-unwrap is safe — 1 step is always under the legacy cap.
        AutoKeysSequence(steps: [.spacebar(after: 1.0)])!
    }

    public static func resolve(
        account: Account,
        all: [Account],
        globalDefault: DefaultMacroBehavior = .skip
    ) -> Resolution {
        // 1. Explicit per-account reference (D-3.5).
        if let refId = account.autoKeysSourceAccountId {
            guard let source = all.first(where: { $0.id == refId }) else {
                return .orphaned(missingSourceAccountId: refId)
            }
            guard let sourceSeq = source.autoKeys, !sourceSeq.isEmpty else {
                return .orphaned(missingSourceAccountId: refId)
            }
            guard sourceSeq.isShared else {
                return .sourceNotShared(sourceAccountId: refId)
            }
            return .sharedFrom(sourceAccountId: refId, sequence: sourceSeq)
        }
        // 2. Own non-empty recording.
        if let own = account.autoKeys, !own.isEmpty {
            return .ownRecording(own)
        }
        // 3. Global default fallback (D-3.8).
        switch globalDefault {
        case .skip:
            return .ownEmpty
        case .stayAlive:
            return .usingGlobalDefault(reason: .stayAlive, sequence: stayAliveSequence())
        case let .useShared(sourceUserId):
            // Self-reference would loop — silently fall through to skip.
            guard sourceUserId != account.userId,
                  let source = all.first(where: { $0.id == sourceUserId }),
                  let sourceSeq = source.autoKeys,
                  !sourceSeq.isEmpty,
                  sourceSeq.isShared else {
                return .ownEmpty
            }
            return .usingGlobalDefault(
                reason: .sharedFrom(sourceAccountId: sourceUserId),
                sequence: sourceSeq
            )
        }
    }

    /// Convenience — returns the sequence to play, or nil if the
    /// account is skipped (any non-playable Resolution case). Used by
    /// the view-model's target builder.
    public static func playableSequence(
        account: Account,
        all: [Account],
        globalDefault: DefaultMacroBehavior = .skip
    ) -> AutoKeysSequence? {
        switch resolve(account: account, all: all, globalDefault: globalDefault) {
        case let .ownRecording(seq):
            return seq
        case let .sharedFrom(_, seq):
            return seq
        case let .usingGlobalDefault(_, seq):
            return seq
        case .ownEmpty, .orphaned, .sourceNotShared:
            return nil
        }
    }
}
