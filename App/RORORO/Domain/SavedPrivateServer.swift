// SavedPrivateServer.swift
// Domain — one Roblox private (VIP) server bookmarked by the user.
//
// Distinct from `LaunchTarget.privateServer`: that's the launch intent;
// this is the persisted record (with name, place name, thumbnail, timestamps).
//
// Stored cross-account. Roblox private servers are scoped to a place +
// link/access code; any signed-in user with the link can join. Per-account
// "stick to this server" behavior would be a preference layer on top —
// not an ownership boundary on the server itself.
//
// Soft credential: a private-server share link is roughly the same trust
// class as a bookmark. Anyone with the link can join, but it doesn't unlock
// the account. Plaintext JSON is appropriate (matches Bloxstrap precedent).
//
// Wire shape stays byte-compatible with RORORO Windows's `SavedPrivateServer`
// record so a future cross-platform import is trivial.

import Foundation

public struct SavedPrivateServer: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let placeId: Int64
    public var code: String
    public var codeKind: PrivateServerCodeKind
    public var name: String
    public var placeName: String
    public var thumbnailURL: URL?
    public let addedAt: Date
    public var lastLaunchedAt: Date?

    public init(
        id: UUID = UUID(),
        placeId: Int64,
        code: String,
        codeKind: PrivateServerCodeKind,
        name: String,
        placeName: String = "",
        thumbnailURL: URL? = nil,
        addedAt: Date = Date(),
        lastLaunchedAt: Date? = nil
    ) {
        self.id = id
        self.placeId = placeId
        self.code = code
        self.codeKind = codeKind
        self.name = name
        self.placeName = placeName
        self.thumbnailURL = thumbnailURL
        self.addedAt = addedAt
        self.lastLaunchedAt = lastLaunchedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case placeId
        case code
        case codeKind
        case name
        case placeName
        case thumbnailURL = "thumbnailUrl"
        case addedAt
        case lastLaunchedAt
    }
}

extension PrivateServerCodeKind: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "linkCode", "LinkCode": self = .linkCode
        case "accessCode", "AccessCode": self = .accessCode
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown PrivateServerCodeKind: \(raw)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        // Match the Windows port's enum casing on the wire ("LinkCode" / "AccessCode").
        switch self {
        case .linkCode: try container.encode("LinkCode")
        case .accessCode: try container.encode("AccessCode")
        }
    }
}
