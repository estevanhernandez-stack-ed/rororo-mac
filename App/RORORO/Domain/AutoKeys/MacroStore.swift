// MacroStore.swift
// Domain — `@MainActor @Observable` library of `Macro`s (Wave D-4.1).
// Sibling to `AccountStore`. Persists `[Macro]` to
// `~/Library/Application Support/RORORO/macros.json` as a separate
// file so accounts.json stays focused on profile data.
//
// **Two-tier model from Slope D-4 onwards:**
//   - Accounts (in `AccountStore`) hold identity + cookie + profile +
//     a reference (`activeMacroId: String?`) to a macro in this store.
//   - Macros (in this store) hold sequences + names + sharing flag +
//     owner attribution.
//
// **Migration entry point:** `migrate(from:)` ingests an `AccountStore`,
// promotes every `Account.autoKeys` to a fresh Macro with the account
// as owner, and rewrites the account list with `activeMacroId` set.
// Idempotent — calling twice does nothing on the second pass because
// accounts whose `autoKeys` was already promoted no longer have a
// non-nil `autoKeys` to migrate from.
//
// The on-disk legacy `Account.autoKeys` payload stays until the
// next AccountStore save — exact same "byte-stable until user
// re-records" posture as ADR 0007 Decision 4.

import Foundation
import Observation

@MainActor
@Observable
public final class MacroStore {

    public static let shared = MacroStore()

    public private(set) var macros: [Macro] = []

    private let storeURL: URL

    private init() {
        self.storeURL = Self.defaultStoreURL()
        load()
    }

    /// Test-only initializer — pass a temp URL.
    internal init(storeURL: URL) {
        self.storeURL = storeURL
        load()
    }

    // MARK: - Public API

    public func macro(id: String) -> Macro? {
        macros.first { $0.id == id }
    }

    /// Every macro owned by a specific account (`ownerUserId` match).
    public func macros(ownedBy userId: String) -> [Macro] {
        macros.filter { $0.ownerUserId == userId }
    }

    /// Every shared macro EXCEPT those owned by the given account —
    /// drives the per-account "use someone else's macro" picker.
    public func sharedMacros(excludingOwner ownerUserId: String? = nil) -> [Macro] {
        macros.filter { m in
            guard m.isShared else { return false }
            if let ownerUserId, m.ownerUserId == ownerUserId { return false }
            return true
        }
    }

    /// Append a new macro. Replaces any existing macro with the same id.
    @discardableResult
    public func upsert(_ macro: Macro) -> Macro {
        macros.removeAll { $0.id == macro.id }
        macros.append(macro)
        save()
        return macro
    }

    /// Rename an existing macro. No-op when the id doesn't exist or the
    /// new name is empty after trimming (the type's normalizer would
    /// fall back to "Untitled", which is not what the user typed).
    public func rename(id: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = macros.firstIndex(where: { $0.id == id }) else { return }
        let existing = macros[idx]
        macros[idx] = Macro(
            id: existing.id,
            name: trimmed,
            ownerUserId: existing.ownerUserId,
            createdAt: existing.createdAt,
            variant: existing.variant,
            isShared: existing.isShared
        )
        save()
    }

    /// Toggle the sharing flag on a macro.
    public func setShared(id: String, isShared: Bool) {
        guard let idx = macros.firstIndex(where: { $0.id == id }) else { return }
        let existing = macros[idx]
        macros[idx] = Macro(
            id: existing.id,
            name: existing.name,
            ownerUserId: existing.ownerUserId,
            createdAt: existing.createdAt,
            variant: existing.variant,
            isShared: isShared
        )
        save()
    }

    /// Delete a macro. The caller is responsible for clearing any
    /// `Account.activeMacroId` references (AccountStore exposes a
    /// cascade helper for this).
    public func delete(id: String) {
        macros.removeAll { $0.id == id }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([Macro].self, from: data) {
            macros = decoded
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(macros)
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // Best-effort write — same posture as AccountStore.save().
        }
    }

    private static func defaultStoreURL() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("RORORO", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("macros.json", isDirectory: false)
    }
}
