// Macro.swift
// Domain — first-class macro entity (Wave D-4.1). The library shape
// promotes recordings out of `Account.autoKeys` (Slope D-3 model where
// each account owned one recording) into the new `MacroStore`. Accounts
// reference macros by `id` via `Account.activeMacroId`; deleting a macro
// cascades to clear any consumer references.
//
// **Why move to a library:** the D-3.5 cross-account sharing reference
// (`autoKeysSourceAccountId`) accumulated cliffs — you could only share
// one macro per account (the one the account recorded), you had to
// re-record to rename or toggle share after the initial save, and
// there was no way to browse what existed across accounts. First-class
// macros decouple identity from ownership: an account can swap which
// macro it plays at any time, multiple accounts can share one macro
// without setting up cross-references, and a "Macros" management view
// (D-4.5) becomes natural.
//
// **Ownership posture:** `ownerUserId` is the account that recorded
// the macro. It's an attribution tag, not a permission boundary —
// any account can pick any shared macro from the library. The owner
// distinction shows up in the row badge ("Using Alice / Combat
// rotation") and helps the user reason about provenance.
//
// **Migration:** on first load with the new MacroStore, any
// `Account.autoKeys` value gets promoted to a Macro with that account
// as owner. The account's `activeMacroId` is set to the new macro's id;
// `autoKeys` is cleared in-memory but the on-disk legacy bytes stay
// until the next save. Downgrade-safety preserved for one release.

import Foundation

public struct Macro: Equatable, Identifiable, Sendable {

    public let id: String
    /// Human-readable label. Always non-empty (init normalizes "" + nil
    /// to a fallback) so the management view never renders a blank row.
    public let name: String
    /// The account that recorded this macro. Tag, not permission — see
    /// file header.
    public let ownerUserId: String?
    public let createdAt: Date
    public let variant: AutoKeysSequence.Variant
    /// Owner-side flag determining whether other accounts can pick this
    /// macro from their per-account picker. Library management view
    /// always shows every macro regardless. Default true for new macros
    /// — the friction of "I have to opt in to share" was a D-3 wart.
    public let isShared: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        ownerUserId: String? = nil,
        createdAt: Date = Date(),
        variant: AutoKeysSequence.Variant,
        isShared: Bool = true
    ) {
        self.id = id
        self.name = Macro.normalize(name: name, ownerUserId: ownerUserId, variant: variant)
        self.ownerUserId = ownerUserId
        self.createdAt = createdAt
        self.variant = variant
        self.isShared = isShared
    }

    public var sequence: AutoKeysSequence {
        AutoKeysSequence(variant: variant, isShared: isShared, name: name)
    }

    public var isEmpty: Bool {
        switch variant {
        case let .legacy(steps): return steps.isEmpty
        case let .stream(actions): return actions.isEmpty
        }
    }

    public var isLegacy: Bool {
        if case .legacy = variant { return true }
        return false
    }

    public var isStream: Bool {
        if case .stream = variant { return true }
        return false
    }

    /// Trim, fall back to a non-empty default if needed. The library UI
    /// renders the name directly; an empty value would produce a blank
    /// row, which is worse than a placeholder.
    private static func normalize(
        name: String,
        ownerUserId: String?,
        variant: AutoKeysSequence.Variant
    ) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        // Fallback — caller didn't provide a meaningful name.
        switch variant {
        case .legacy: return "Untitled (legacy)"
        case .stream: return "Untitled"
        }
    }
}

// MARK: - Codable

extension Macro: Codable {

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case ownerUserId
        case createdAt
        case sequence
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        let name = try c.decode(String.self, forKey: .name)
        let ownerUserId = try c.decodeIfPresent(String.self, forKey: .ownerUserId)
        let createdAt = try c.decode(Date.self, forKey: .createdAt)
        // Variant + isShared live inside the embedded AutoKeysSequence
        // payload — reuse its Codable contract so the on-disk shape
        // mirrors the D-3 stream/legacy split exactly.
        let seq = try c.decode(AutoKeysSequence.self, forKey: .sequence)
        self.init(
            id: id,
            name: name,
            ownerUserId: ownerUserId,
            createdAt: createdAt,
            variant: seq.variant,
            isShared: seq.isShared
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(ownerUserId, forKey: .ownerUserId)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(sequence, forKey: .sequence)
    }
}
