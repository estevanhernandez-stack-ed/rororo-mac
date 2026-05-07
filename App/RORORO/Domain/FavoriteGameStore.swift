// FavoriteGameStore.swift
// Domain — `@MainActor @Observable` list of saved Roblox games.
//
// Persistence: plaintext JSON at
// `~/Library/Application Support/RORORO/favorites.json`.
// Wire shape: `{ "version": 1, "favorites": [...] }` — byte-compatible
// with RORORO Windows so a future cross-platform import is trivial.
//
// Default-flag invariant: at most one entry has `isDefault = true`.
// `setDefault(placeId:)` enforces by clearing all others. `add(...)`
// auto-marks the first entry as default. `remove(...)` promotes the
// next entry if it removed the default.
//
// Migration from v0.1.x: the previous incarnation stored a single URL
// in UserDefaults (`RORORO.defaultGameURL`). On first v0.2 launch we
// detect a non-empty value and seed the favorites list with one entry
// derived from it (`isDefault = true`). Background metadata fetch
// enriches name + icon. The UserDefault key is cleared post-migration
// so subsequent edits flow through the new store.

import Foundation
import Observation

@MainActor
@Observable
public final class FavoriteGameStore {

    public static let shared = FavoriteGameStore()

    public private(set) var favorites: [FavoriteGame] = []

    /// Storage path for the JSON blob. Tests pass an override.
    private let storeURL: URL

    /// v0.1.x default-game URL key. Read once on init for migration; cleared
    /// after migration runs.
    public static let legacyDefaultGameURLKey = "RORORO.defaultGameURL"

    private init() {
        self.storeURL = Self.defaultStoreURL()
        load()
        migrateLegacyDefaultGameURLIfNeeded()
    }

    /// Test seam.
    internal init(storeURL: URL) {
        self.storeURL = storeURL
        load()
    }

    // MARK: - Read

    public func defaultGame() -> FavoriteGame? {
        favorites.first(where: { $0.isDefault })
    }

    // MARK: - Write

    /// Insert or update a favorite. The first entry added is automatically
    /// marked default. Re-adding an existing placeId preserves its
    /// `isDefault` flag and `addedAt` timestamp.
    @discardableResult
    public func add(
        placeId: Int64,
        universeId: Int64,
        name: String,
        thumbnailURL: URL? = nil
    ) -> FavoriteGame {
        if let idx = favorites.firstIndex(where: { $0.placeId == placeId }) {
            let existing = favorites[idx]
            let updated = FavoriteGame(
                placeId: placeId,
                universeId: universeId,
                name: name,
                thumbnailURL: thumbnailURL,
                isDefault: existing.isDefault,
                addedAt: existing.addedAt
            )
            favorites[idx] = updated
            save()
            return updated
        }
        let isFirst = favorites.isEmpty
        let new = FavoriteGame(
            placeId: placeId,
            universeId: universeId,
            name: name,
            thumbnailURL: thumbnailURL,
            isDefault: isFirst,
            addedAt: Date()
        )
        favorites.append(new)
        save()
        return new
    }

    public func remove(placeId: Int64) {
        guard let idx = favorites.firstIndex(where: { $0.placeId == placeId }) else { return }
        let wasDefault = favorites[idx].isDefault
        favorites.remove(at: idx)
        // Promote the first remaining entry if we just removed the default.
        if wasDefault, !favorites.isEmpty {
            favorites[0].isDefault = true
        }
        save()
    }

    /// Clear all `isDefault` flags then mark the named placeId as default.
    /// Also clears the PrivateServerStore's default — only one entry
    /// across both stores can be the default at a time.
    /// No-op if placeId isn't in the list.
    public func setDefault(placeId: Int64) {
        guard favorites.contains(where: { $0.placeId == placeId }) else { return }
        for i in favorites.indices {
            favorites[i].isDefault = (favorites[i].placeId == placeId)
        }
        save()
        PrivateServerStore.shared.clearDefaultFlag()
    }

    /// Clear isDefault on all entries. Called by PrivateServerStore.setDefault
    /// to maintain the cross-store invariant. Does NOT call back.
    public func clearDefaultFlag() {
        var changed = false
        for i in favorites.indices where favorites[i].isDefault {
            favorites[i].isDefault = false
            changed = true
        }
        if changed { save() }
    }

    /// Update display fields without touching `isDefault`. Called by the
    /// background metadata-fetch path.
    public func updateMetadata(
        placeId: Int64,
        name: String? = nil,
        thumbnailURL: URL? = nil
    ) {
        guard let idx = favorites.firstIndex(where: { $0.placeId == placeId }) else { return }
        if let name { favorites[idx].name = name }
        if let thumbnailURL { favorites[idx].thumbnailURL = thumbnailURL }
        save()
    }

    /// User-facing rename. Trims whitespace; no-ops on empty input so we
    /// don't write blank rows.
    public func rename(placeId: Int64, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = favorites.firstIndex(where: { $0.placeId == placeId }) else { return }
        favorites[idx].name = trimmed
        save()
    }

    // MARK: - Persistence

    private struct Blob: Codable {
        let version: Int
        var favorites: [FavoriteGame]
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let blob = try? decoder.decode(Blob.self, from: data) {
            favorites = blob.favorites
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let blob = Blob(version: 1, favorites: favorites)
            let data = try encoder.encode(blob)
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Atomic write via tmp + rename — matches the Windows port's pattern.
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // Best-effort. UI can surface via DiagnosticsView.lastError later.
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
        return dir.appendingPathComponent("favorites.json", isDirectory: false)
    }

    // MARK: - v0.1.x migration

    /// One-time migration: v0.1.x stored a single URL in UserDefaults.
    /// Convert it to a FavoriteGame entry, mark default, kick off a
    /// background metadata fetch to enrich name + icon, then clear the
    /// UserDefault key so subsequent edits flow through this store.
    private func migrateLegacyDefaultGameURLIfNeeded() {
        guard favorites.isEmpty else { return }
        let defaults = UserDefaults.standard
        guard let urlString = defaults.string(forKey: Self.legacyDefaultGameURLKey),
              !urlString.isEmpty else { return }
        guard case .place(let placeId) = LaunchTarget.fromUrl(urlString) else {
            // Not a parseable place URL — clear the legacy key but don't
            // seed favorites. User will re-add via the new UI.
            defaults.removeObject(forKey: Self.legacyDefaultGameURLKey)
            return
        }

        // Seed with a placeholder name; metadata fetch enriches.
        let placeholder = FavoriteGame(
            placeId: placeId,
            universeId: 0,
            name: "Place \(placeId)",
            thumbnailURL: nil,
            isDefault: true,
            addedAt: Date()
        )
        favorites = [placeholder]
        save()
        defaults.removeObject(forKey: Self.legacyDefaultGameURLKey)

        // Background metadata fetch. Failures are silent — the user gets
        // a row with the placeId-derived name and can edit later.
        Task.detached { [weak self] in
            guard let metadata = try? await RobloxApi.getGameMetadata(placeId: placeId) else { return }
            await MainActor.run {
                guard let self else { return }
                if let idx = self.favorites.firstIndex(where: { $0.placeId == placeId }) {
                    var updated = self.favorites[idx]
                    updated.name = metadata.name
                    updated.thumbnailURL = metadata.iconURL
                    // universeId is `let` on the struct; we can't update it
                    // in place. Replace the row with a fresh struct that
                    // preserves isDefault + addedAt.
                    self.favorites[idx] = FavoriteGame(
                        placeId: updated.placeId,
                        universeId: metadata.universeId,
                        name: metadata.name,
                        thumbnailURL: metadata.iconURL,
                        isDefault: updated.isDefault,
                        addedAt: updated.addedAt
                    )
                    self.save()
                }
            }
        }
    }
}
