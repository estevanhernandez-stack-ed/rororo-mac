// FavoriteGame.swift
// Domain — one Roblox game saved by the user. Persisted as JSON in
// `~/Library/Application Support/RORORO/favorites.json` (plaintext;
// these are preferences, not secrets — same trust class as a browser
// bookmark).
//
// Wire shape stays byte-compatible with RORORO Windows's `FavoriteGame`
// record so a future "Import from Windows" flow doesn't need migration:
// same field names (camelCase via CodingKeys), same blob shape
// `{ "version": 1, "favorites": [...] }`.
//
// `isDefault` flags the entry that Launch As uses when the user clicks
// without picking — exactly one entry should be marked default at a time.
// `FavoriteGameStore.setDefault(placeId:)` enforces the invariant.

import Foundation

public struct FavoriteGame: Codable, Equatable, Identifiable, Sendable {
    public let placeId: Int64
    public let universeId: Int64
    public var name: String
    public var thumbnailURL: URL?
    public var isDefault: Bool
    public let addedAt: Date

    public var id: Int64 { placeId }

    public init(
        placeId: Int64,
        universeId: Int64,
        name: String,
        thumbnailURL: URL? = nil,
        isDefault: Bool = false,
        addedAt: Date = Date()
    ) {
        self.placeId = placeId
        self.universeId = universeId
        self.name = name
        self.thumbnailURL = thumbnailURL
        self.isDefault = isDefault
        self.addedAt = addedAt
    }

    private enum CodingKeys: String, CodingKey {
        case placeId
        case universeId
        case name
        case thumbnailURL = "thumbnailUrl"
        case isDefault
        case addedAt
    }
}
