// AutoKeysSequence.swift
// Domain — ordered list of up to 3 `AutoKeysStep`s for one account
// (Slope C). Per ADR 0004 Decision 2, the cap is enforced at both
// construction and decode time so a hand-edited `accounts.json` can't
// sneak a 4-step sequence past us.
//
// `totalDuration` is the input to `CycleBudget.estimate`; an empty
// sequence (or nil on the Account) means the cycler skips the account.

import Foundation

public struct AutoKeysSequence: Codable, Equatable, Sendable {

    public static let maxSteps = 3

    public let steps: [AutoKeysStep]

    /// Failable — returns nil when `steps.count > maxSteps`. Empty is allowed
    /// and represents "configured but no steps" (cycler skips the account).
    public init?(steps: [AutoKeysStep]) {
        guard steps.count <= Self.maxSteps else { return nil }
        self.steps = steps
    }

    /// Σ(delayAfter) — one walk through the sequence. Used by `CycleBudget`.
    public var totalDuration: TimeInterval {
        steps.reduce(0) { $0 + $1.delayAfter }
    }

    public var isEmpty: Bool { steps.isEmpty }

    // MARK: - Codable (custom to enforce the cap on decode)

    private enum CodingKeys: String, CodingKey {
        case steps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([AutoKeysStep].self, forKey: .steps)
        guard decoded.count <= Self.maxSteps else {
            throw DecodingError.dataCorruptedError(
                forKey: .steps,
                in: container,
                debugDescription: "AutoKeysSequence exceeds max \(Self.maxSteps) steps (got \(decoded.count))"
            )
        }
        self.steps = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(steps, forKey: .steps)
    }
}
