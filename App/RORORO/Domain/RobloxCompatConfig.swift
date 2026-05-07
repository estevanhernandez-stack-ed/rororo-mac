// RobloxCompatConfig.swift
// Domain — wire shape for `roblox-compat.json` published at
// `https://estevanhernandez-stack-ed.github.io/rororo-mac/roblox-compat.json`.
//
// Lets us push semaphore-name updates within minutes if Roblox renames
// `/RobloxPlayerUniq`, without cutting an app release. Decoupled from
// the appcast on purpose — the appcast publishes per-tag; this can be
// hot-pushed.
//
// Schema versioning: bump `version` when the shape changes. The store
// rejects unknown versions and falls back to hardcoded values.

import Foundation

public struct RobloxCompatConfig: Codable, Equatable, Sendable {
    public let version: Int
    public let semaphoreName: String
    public let knownGoodRobloxVersion: String?
    public let minimumAppVersion: String?
    public let updatedAt: Date

    public init(
        version: Int = 1,
        semaphoreName: String,
        knownGoodRobloxVersion: String? = nil,
        minimumAppVersion: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.version = version
        self.semaphoreName = semaphoreName
        self.knownGoodRobloxVersion = knownGoodRobloxVersion
        self.minimumAppVersion = minimumAppVersion
        self.updatedAt = updatedAt
    }
}
