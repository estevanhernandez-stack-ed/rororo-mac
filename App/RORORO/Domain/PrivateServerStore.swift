// PrivateServerStore.swift
// Domain — `@MainActor @Observable` list of saved Roblox private servers.
//
// Persistence: plaintext JSON at
// `~/Library/Application Support/RORORO/private-servers.json`.
// Wire shape: `{ "version": 1, "servers": [...] }` — byte-compatible with
// RORORO Windows so a future cross-platform import is trivial.
//
// Identity: each entry has a stable `UUID` so renames don't break per-row
// references in the UI. Add-by-(placeId, code) replaces an existing row
// preserving its UUID + addedAt — a user re-pasting the same share URL
// with a different display name updates the row in place.
//
// Soft credential: see SavedPrivateServer.swift.

import Foundation
import Observation

@MainActor
@Observable
public final class PrivateServerStore {

    public static let shared = PrivateServerStore()

    public private(set) var servers: [SavedPrivateServer] = []

    private let storeURL: URL

    private init() {
        self.storeURL = Self.defaultStoreURL()
        load()
    }

    /// Test seam.
    internal init(storeURL: URL) {
        self.storeURL = storeURL
        load()
    }

    public func get(id: UUID) -> SavedPrivateServer? {
        servers.first(where: { $0.id == id })
    }

    /// Insert or update by (placeId, code) pair. Re-pasting the same share
    /// URL with a different display name updates in place — preserves UUID
    /// + addedAt so per-row UI references survive.
    @discardableResult
    public func add(
        placeId: Int64,
        code: String,
        codeKind: PrivateServerCodeKind,
        name: String,
        placeName: String = "",
        thumbnailURL: URL? = nil
    ) -> SavedPrivateServer {
        if let idx = servers.firstIndex(where: { $0.placeId == placeId && $0.code == code }) {
            let existing = servers[idx]
            let updated = SavedPrivateServer(
                id: existing.id,
                placeId: placeId,
                code: code,
                codeKind: codeKind,
                name: name,
                placeName: placeName,
                thumbnailURL: thumbnailURL,
                addedAt: existing.addedAt,
                lastLaunchedAt: existing.lastLaunchedAt,
                isDefault: existing.isDefault
            )
            servers[idx] = updated
            save()
            return updated
        }
        let new = SavedPrivateServer(
            id: UUID(),
            placeId: placeId,
            code: code,
            codeKind: codeKind,
            name: name,
            placeName: placeName,
            thumbnailURL: thumbnailURL,
            addedAt: Date(),
            lastLaunchedAt: nil
        )
        servers.append(new)
        save()
        return new
    }

    public func remove(id: UUID) {
        servers.removeAll(where: { $0.id == id })
        save()
    }

    public func touchLastLaunched(id: UUID, at date: Date = Date()) {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[idx].lastLaunchedAt = date
        save()
    }

    /// Update display fields without changing identity. Used by the
    /// background metadata-fetch path.
    public func updateMetadata(
        id: UUID,
        placeName: String? = nil,
        thumbnailURL: URL? = nil
    ) {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        if let placeName { servers[idx].placeName = placeName }
        if let thumbnailURL { servers[idx].thumbnailURL = thumbnailURL }
        save()
    }

    /// User-facing rename. Trims whitespace; no-ops on empty input.
    public func rename(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[idx].name = trimmed
        save()
    }

    /// Returns the entry currently flagged as default, if any.
    public func defaultServer() -> SavedPrivateServer? {
        servers.first(where: { $0.isDefault })
    }

    /// Clear all `isDefault` flags then mark the named server as default.
    /// Also clears the FavoriteGameStore's default — only one entry across
    /// both stores can be the default at a time.
    public func setDefault(id: UUID) {
        guard servers.contains(where: { $0.id == id }) else { return }
        for i in servers.indices {
            servers[i].isDefault = (servers[i].id == id)
        }
        save()
        // Cross-store: clear the favorites' default to maintain the
        // single-default invariant. clearDefaultFlag does NOT call back.
        FavoriteGameStore.shared.clearDefaultFlag()
    }

    /// Clear isDefault on all entries in this store. Called by
    /// FavoriteGameStore.setDefault to maintain the cross-store invariant.
    /// Does NOT call back into FavoriteGameStore — the call site
    /// (FavoriteGameStore.setDefault) already updated its own flags.
    public func clearDefaultFlag() {
        var changed = false
        for i in servers.indices where servers[i].isDefault {
            servers[i].isDefault = false
            changed = true
        }
        if changed { save() }
    }

    // MARK: - Persistence

    private struct Blob: Codable {
        let version: Int
        var servers: [SavedPrivateServer]
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let blob = try? decoder.decode(Blob.self, from: data) {
            servers = blob.servers
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let blob = Blob(version: 1, servers: servers)
            let data = try encoder.encode(blob)
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // Best-effort. UI surfaces via DiagnosticsView.lastError later.
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
        return dir.appendingPathComponent("private-servers.json", isDirectory: false)
    }
}
