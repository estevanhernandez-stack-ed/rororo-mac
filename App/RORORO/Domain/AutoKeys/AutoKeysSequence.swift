// AutoKeysSequence.swift
// Domain — auto-keys recording for one account. As of Wave D-3.1
// (ADR 0007) the sequence is a wrapper around a two-shape variant:
//
//   - `.legacy([AutoKeysStep])` — pre-ADR-0007 keys-only step list from
//     ADR 0004. Decodes from existing on-disk payloads (`{"steps":[…]}`)
//     and re-encodes to the same shape on save so legacy bytes stay
//     stable until the user re-records (ADR 0007 Decision 4). The
//     cycler routes legacy variants through the existing step loop.
//   - `.stream([AutoKeysAction])` — the new full-fidelity action stream
//     (ADR 0007 Decision 1). 500-action cap enforced at init. The
//     `isShared` flag (Decision 7) marks the sequence as eligible for
//     other accounts to reference via `Account.autoKeysSourceAccountId`.
//
// `steps` and `actions` are computed accessors that surface the variant
// payload — callers that don't care about which path they're looking at
// can treat the empty fallback as "no work to do." Used by the row
// badge today; replaced wholesale in D-3.4.
//
// On-disk shape:
//   - Legacy:  `{"steps":[…]}`               (unchanged from ADR 0004)
//   - Stream:  `{"actions":[…],"isShared":bool}`
//
// The decoder picks the variant by looking for `actions` first, then
// falling back to `steps`. No `kind` discriminator — keeps the legacy
// shape byte-stable.

import Foundation

public struct AutoKeysSequence: Codable, Equatable, Sendable {

    /// Maximum action count for a stream-variant sequence (ADR 0007
    /// Decision 1). Sized to bound serialization (~30 KB at ~60 B per
    /// action) and bound the cycler's per-account budget — 500 actions
    /// at ~16 ms/frame is ~8 s of dense input, well under the 19-minute
    /// cycle cap from ADR 0004 Decision 4.
    public static let maxActionCount: Int = 500

    public enum Variant: Equatable, Sendable {
        case legacy([AutoKeysStep])
        case stream([AutoKeysAction])
    }

    public let variant: Variant
    /// Owner-side sharing flag (ADR 0007 Decision 7). Only meaningful for
    /// `.stream` variants — legacy sequences require a re-record to
    /// share. Default false so opting in is explicit.
    public let isShared: Bool
    /// Optional user-supplied label for this recording — e.g. "Combat
    /// rotation", "Farming loop", "AFK jump-spam". Surfaces in the row
    /// badge, the sharing picker, and post-record review. nil ≡
    /// unnamed (the sequence falls back to action-count + duration in
    /// the badge). Legacy variants don't carry names — re-record to
    /// promote to stream and add one.
    public let name: String?

    // MARK: - Init

    /// Legacy entry point — preserved for backward source compat with the
    /// recorder sheet that still produces step lists. Always succeeds
    /// (the original 3-step cap was lifted in wave 3c). Failable for
    /// historical symmetry — callers may pass-through `nil`.
    public init?(steps: [AutoKeysStep]) {
        self.variant = .legacy(steps)
        self.isShared = false
        self.name = nil
    }

    /// Stream entry point — produces a `.stream` variant. Returns nil if
    /// `actions.count > maxActionCount` (ADR 0007 Decision 1 cap).
    public init?(
        actions: [AutoKeysAction],
        isShared: Bool = false,
        name: String? = nil
    ) {
        guard actions.count <= Self.maxActionCount else { return nil }
        self.variant = .stream(actions)
        self.isShared = isShared
        self.name = Self.normalize(name: name)
    }

    /// Direct-variant entry point — used by tests and migration. Does
    /// not enforce the action cap (callers building from already-validated
    /// data don't need it re-checked). Production code paths funnel
    /// through `init?(actions:)` or the legacy `init?(steps:)`.
    public init(variant: Variant, isShared: Bool = false, name: String? = nil) {
        self.variant = variant
        self.isShared = isShared
        // Legacy variants can't carry a name — the on-disk shape is
        // byte-stable per ADR 0007 Decision 4. Drop name for legacy.
        switch variant {
        case .legacy: self.name = nil
        case .stream: self.name = Self.normalize(name: name)
        }
    }

    /// Trim + nil-empty-string. Whitespace-only or empty names collapse
    /// to nil so the badge doesn't render a stray dot.
    private static func normalize(name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    // MARK: - Accessors

    /// Legacy steps for a `.legacy` variant; empty for `.stream`.
    public var steps: [AutoKeysStep] {
        if case let .legacy(s) = variant { return s }
        return []
    }

    /// Action stream for a `.stream` variant; empty for `.legacy`.
    public var actions: [AutoKeysAction] {
        if case let .stream(a) = variant { return a }
        return []
    }

    public var isLegacy: Bool {
        if case .legacy = variant { return true }
        return false
    }

    public var isStream: Bool {
        if case .stream = variant { return true }
        return false
    }

    public var isEmpty: Bool {
        switch variant {
        case let .legacy(s): return s.isEmpty
        case let .stream(a): return a.isEmpty
        }
    }

    /// Total wall-clock duration of one walk through the sequence.
    /// Legacy: Σ(`delayAfter` + intra-repeat gaps) — matches the original
    /// ADR 0004 math. Stream: Σ(`dt`) — sum of inter-action gaps.
    /// Used by `CycleBudget.estimate` against the 19-minute hard cap.
    public var totalDuration: TimeInterval {
        switch variant {
        case let .legacy(steps):
            return steps.reduce(0) { acc, step in
                let repeats = max(0, step.repeatCount - 1)
                return acc + step.delayAfter + Double(repeats) * AutoKeysStep.intraRepeatInterval
            }
        case let .stream(actions):
            return actions.reduce(0) { $0 + $1.dt }
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case steps
        case actions
        case isShared
        case name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Prefer the stream shape — newer recordings ship with `actions`.
        // Fall back to legacy `steps` so on-disk ADR-0004 sequences load
        // unchanged.
        if c.contains(.actions) {
            let actions = try c.decode([AutoKeysAction].self, forKey: .actions)
            let shared = try c.decodeIfPresent(Bool.self, forKey: .isShared) ?? false
            let name = try c.decodeIfPresent(String.self, forKey: .name)
            self.variant = .stream(actions)
            self.isShared = shared
            self.name = Self.normalize(name: name)
        } else if c.contains(.steps) {
            let steps = try c.decode([AutoKeysStep].self, forKey: .steps)
            self.variant = .legacy(steps)
            self.isShared = false
            self.name = nil
        } else {
            // No payload at all → treat as empty legacy. Defensive — the
            // shape shouldn't reach disk but won't crash if it does.
            self.variant = .legacy([])
            self.isShared = false
            self.name = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch variant {
        case let .legacy(steps):
            // Re-emit the byte-stable ADR-0004 shape so legacy on-disk
            // payloads round-trip unchanged. `isShared` + `name` are
            // meaningless for legacy and omitted to keep diffs clean
            // (Decision 4).
            try c.encode(steps, forKey: .steps)
        case let .stream(actions):
            try c.encode(actions, forKey: .actions)
            try c.encode(isShared, forKey: .isShared)
            try c.encodeIfPresent(name, forKey: .name)
        }
    }
}
