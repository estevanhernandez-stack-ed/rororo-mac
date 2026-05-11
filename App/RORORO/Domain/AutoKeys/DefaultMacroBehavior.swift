// DefaultMacroBehavior.swift
// Domain — global setting (D-3.8) that decides what to do for accounts
// without their own recording and without an explicit sharing
// reference. The third tier of the auto-keys playback waterfall:
//
//   1. account.autoKeysSourceAccountId  → explicit reference (D-3.5)
//   2. account.autoKeys (non-empty)     → own recording (D-3.1+)
//   3. LaunchSettingsStore.defaultMacroBehavior → THIS                (D-3.8)
//   4. Resolution.ownEmpty              → cycler skips the account
//
// Default `.skip` preserves pre-D-3.8 semantics — an account without
// its own recording is silently skipped. The user can switch to
// `.stayAlive` to keep all unconfigured accounts breathing (synthesized
// spacebar after a brief delay) or `.useShared(sourceUserId:)` to point
// every unconfigured account at one specific shared recording.
//
// **Distinct from `LaunchSettingsStore.autoKeysStayAwakeMode`** —
// stay-awake mode is a global OVERRIDE (every running account gets
// synthesized spacebar, custom recordings ignored). This default is
// the FALLBACK only — custom recordings still win when present.
// They coexist; stay-awake wins when both are configured.

import Foundation

public enum DefaultMacroBehavior: Codable, Equatable, Sendable {
    /// No fallback — the cycler skips an account that has neither its
    /// own recording nor an explicit sharing reference. Default.
    case skip
    /// Built-in synthesis: focus → wait ~1 s → press spacebar → next.
    /// Identical shape to the existing stay-awake-mode sequence; this
    /// just plumbs it as a fallback instead of a blanket override.
    case stayAlive
    /// Point the fallback at a specific account's shared recording.
    /// The source must have `isShared = true` on its `AutoKeysSequence`
    /// — broken references silently fall through to `.skip` at resolve
    /// time (and the toolbar's picker SHOULD warn the user separately).
    case useShared(sourceUserId: String)

    // MARK: - Codable (tagged shape for forward stability)

    private enum Kind: String, Codable {
        case skip
        case stayAlive
        case useShared
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case sourceUserId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .skip:
            self = .skip
        case .stayAlive:
            self = .stayAlive
        case .useShared:
            let userId = try c.decode(String.self, forKey: .sourceUserId)
            self = .useShared(sourceUserId: userId)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .skip:
            try c.encode(Kind.skip, forKey: .kind)
        case .stayAlive:
            try c.encode(Kind.stayAlive, forKey: .kind)
        case let .useShared(userId):
            try c.encode(Kind.useShared, forKey: .kind)
            try c.encode(userId, forKey: .sourceUserId)
        }
    }
}
