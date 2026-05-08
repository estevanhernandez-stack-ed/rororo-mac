// Account.swift
// Domain — value type representing a saved Roblox account in the vault.
//
// `userId` is the canonical identity (Roblox userId as a String for JSON
// stability — Int64 in the wire shape). `username` is the immutable
// account handle; `displayName` is the user-facing label that can change.
// `avatarThumbnailURL` is fetched lazily from Roblox's thumbnails API
// and cached here so the UI can show a face without a re-fetch on every
// launch. `lastLaunchedAt` is updated by AccountStore.touchLastLaunched
// after every successful Launch As — drives sort order in the UI.
//
// The Codable shape is the on-disk format (`accounts.json`). Cookies do
// NOT live in this struct — they're stored separately in Keychain via
// KeychainStore. JSON file holds public profile data only.

import Foundation

public struct Account: Codable, Equatable, Identifiable, Sendable {
    public let userId: String
    public let username: String
    public var displayName: String
    public var avatarThumbnailURL: URL?
    public var lastLaunchedAt: Date?
    /// Per-account frame-rate cap override (Slope A3). nil → fall back to
    /// `LaunchSettingsStore.shared.framerateCap` (the global setting); a
    /// concrete value wins regardless of the global. Race caveat: if the
    /// user rapid-fires Launch As across two accounts with different
    /// overrides within the same engine-startup window, the second
    /// XML write may land before the first Roblox has read it — the
    /// observed cap collapses to the last-written value. Sequential
    /// clicks (the normal flow) work cleanly.
    public var framerateCapOverride: Int?

    public var id: String { userId }

    public init(
        userId: String,
        username: String,
        displayName: String,
        avatarThumbnailURL: URL? = nil,
        lastLaunchedAt: Date? = nil,
        framerateCapOverride: Int? = nil
    ) {
        self.userId = userId
        self.username = username
        self.displayName = displayName
        self.avatarThumbnailURL = avatarThumbnailURL
        self.lastLaunchedAt = lastLaunchedAt
        self.framerateCapOverride = framerateCapOverride
    }
}
