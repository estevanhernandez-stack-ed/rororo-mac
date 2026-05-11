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
    /// Last-known health of the saved `.ROBLOSECURITY` cookie (Slope B3').
    /// nil ≡ never-probed (treated as .unknown by callers). Surfaces
    /// expiry to the row UI BEFORE the user clicks Launch As — historically
    /// expiry only manifested at launch-fail time with a generic alert.
    public var cookieStatus: CookieStatus?
    /// Wall-clock of the last cookie-health probe. Lets the UI show
    /// "checked Nm ago" if/when we add a manual refresh affordance.
    /// Updated by AccountStore.refreshAllAccounts on every probe pass.
    public var cookieCheckedAt: Date?
    /// User-assigned group label (Slope B1). nil ≡ ungrouped — accounts
    /// fall into a default top-of-list section. Multiple accounts with
    /// the same `groupName` cluster under one section header in
    /// AccountsListView, and the section gets a "Launch group" button
    /// that enqueues a launch per member through MultiInstanceCoordinator's
    /// serial queue (B0). No fixed schema — group name is whatever the
    /// user types ("alts", "friends to play with", "grinding").
    public var groupName: String?
    /// **Deprecated as of D-4** — recordings live in `MacroStore` now,
    /// referenced from this account via `activeMacroId`. This field
    /// stays on the type for one release to keep the migration path
    /// readable: `AutoKeysLibraryMigrator` reads pre-D-4 on-disk values
    /// here and promotes them to library macros. Production code
    /// paths past D-4.4 never write to this field. On-disk shape is
    /// preserved until the next `AccountStore.save()` after migration.
    public var autoKeys: AutoKeysSequence?
    /// Shared-recording reference (ADR 0007 Decision 7). When set, the
    /// cycler resolves this account's playback through the *source*
    /// account's `autoKeys` instead of its own. **Deprecated as of
    /// D-4.2** — the library migration translates this field into
    /// `activeMacroId` pointing at the owner's migrated macro. Kept on
    /// the type for one release for downgrade-safety; new code paths
    /// never write to it.
    public var autoKeysSourceAccountId: Account.ID?
    /// D-4.2 — the macro this account currently plays. Resolves
    /// against `MacroStore`. nil ≡ "no macro selected" (cycler skips
    /// the account unless the global default applies). The library
    /// migration sets this from the legacy `autoKeys` /
    /// `autoKeysSourceAccountId` fields on first boot.
    public var activeMacroId: String?

    public var id: String { userId }

    public init(
        userId: String,
        username: String,
        displayName: String,
        avatarThumbnailURL: URL? = nil,
        lastLaunchedAt: Date? = nil,
        framerateCapOverride: Int? = nil,
        cookieStatus: CookieStatus? = nil,
        cookieCheckedAt: Date? = nil,
        groupName: String? = nil,
        autoKeys: AutoKeysSequence? = nil,
        autoKeysSourceAccountId: Account.ID? = nil,
        activeMacroId: String? = nil
    ) {
        self.userId = userId
        self.username = username
        self.displayName = displayName
        self.avatarThumbnailURL = avatarThumbnailURL
        self.lastLaunchedAt = lastLaunchedAt
        self.framerateCapOverride = framerateCapOverride
        self.cookieStatus = cookieStatus
        self.cookieCheckedAt = cookieCheckedAt
        self.groupName = groupName
        self.autoKeys = autoKeys
        self.autoKeysSourceAccountId = autoKeysSourceAccountId
        self.activeMacroId = activeMacroId
    }
}

/// Last-known health of the `.ROBLOSECURITY` cookie. Stored on Account
/// so the UI can surface expiry per-row without re-probing on every
/// render. Probed on app boot via AccountStore.refreshAllCookieStatuses
/// and on launch-time `APIError.cookieExpired` interception.
public enum CookieStatus: String, Codable, Equatable, Sendable {
    /// Probed within recent memory and Roblox accepted the cookie.
    case healthy
    /// Probe got a 401 — the cookie is no longer valid for auth ticket
    /// or user-profile calls. The user needs to re-login (inline via
    /// CookieCapture, or by remove + re-add).
    case expired
    /// Probed but Roblox returned a transient error (5xx, network).
    /// Treated like `.unknown` for badge UX; we'll re-probe later.
    case transient
}
