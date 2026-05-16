// AccountStore.swift
// Domain — `@MainActor @Observable` vault for saved Roblox accounts.
//
// Two-tier storage:
//   - Public profile data → JSON at `~/Library/Application Support/RORORO/accounts.json`
//   - Cookies (`.ROBLOSECURITY`) → Keychain via `KeychainStore` (one item
//     per account, keyed by Roblox `userId`).
//
// The split keeps cookies out of any backup that touches the JSON. iCloud
// Drive, Time Machine, and rsync-style sync tools all happily slurp
// Application Support — but not the Keychain. Reformatting to put cookies
// in JSON would be a regression.
//
// Test seam: `AccountStore(storeURL:)` is internal (visible to tests via
// `@testable import RORORO`) — tests pass a temp URL plus enable
// `KeychainStore.inMemoryOverride` to keep both surfaces clean.

import Foundation
import Observation

@MainActor
@Observable
public final class AccountStore {

    public static let shared = AccountStore()

    public private(set) var accounts: [Account] = []

    /// Test-only seam. `@testable import` exposes this to ROROROTests.
    /// Not part of the public API — bypasses the Keychain write that
    /// `add(account:cookie:)` performs, so integration tests can drive
    /// the account count without setting up a real keychain.
    internal func _setAccountsForTesting(_ accounts: [Account]) {
        self.accounts = accounts
    }

    /// JSON file location. Production resolves to
    /// `~/Library/Application Support/RORORO/accounts.json`. Tests pass
    /// a temp path via the internal initializer.
    private let storeURL: URL

    private init() {
        self.storeURL = Self.defaultStoreURL()
        load()
    }

    /// Test-only initializer. Production callers use `.shared`.
    internal init(storeURL: URL) {
        self.storeURL = storeURL
        load()
    }

    public func add(account: Account, cookie: String) throws {
        try KeychainStore.set(
            service: KeychainStore.cookieService,
            account: account.userId,
            value: cookie
        )
        // Replace any existing record for the same userId — re-add over
        // a stale account (e.g. user re-logged in to refresh a dead cookie)
        // refreshes the public-profile data without orphaning the entry.
        accounts.removeAll { $0.userId == account.userId }
        accounts.append(account)
        save()
    }

    public func remove(userId: String) throws {
        try KeychainStore.delete(
            service: KeychainStore.cookieService,
            account: userId
        )
        accounts.removeAll { $0.userId == userId }
        save()
    }

    /// Pull a cookie for launching. Returns nil when the account is gone
    /// from Keychain (e.g. user wiped Keychain manually). UI surface
    /// re-prompts for login in that case.
    public func cookie(for userId: String) throws -> String? {
        try KeychainStore.get(
            service: KeychainStore.cookieService,
            account: userId
        )
    }

    /// Update the public-profile fields (displayName + avatar) without
    /// re-saving the cookie. Call after fetching fresh data from
    /// `RobloxApi.getUserProfile` post-launch.
    public func updateProfile(
        userId: String,
        displayName: String? = nil,
        avatarThumbnailURL: URL? = nil
    ) {
        guard let idx = accounts.firstIndex(where: { $0.userId == userId }) else { return }
        if let displayName { accounts[idx].displayName = displayName }
        if let avatarThumbnailURL { accounts[idx].avatarThumbnailURL = avatarThumbnailURL }
        save()
    }

    public func touchLastLaunched(userId: String, at date: Date = Date()) {
        guard let idx = accounts.firstIndex(where: { $0.userId == userId }) else { return }
        accounts[idx].lastLaunchedAt = date
        save()
    }

    /// Set or clear the per-account frame-rate cap override. Pass `nil` to
    /// revert the account to the global `LaunchSettingsStore` cap. No-op
    /// when `userId` doesn't match a saved account.
    public func setFramerateCapOverride(userId: String, cap: Int?) {
        guard let idx = accounts.firstIndex(where: { $0.userId == userId }) else { return }
        accounts[idx].framerateCapOverride = cap
        save()
    }

    /// Update the cookie health status + checked-at timestamp for one
    /// account. Called by the boot-time probe + by RobloxLauncher on
    /// `APIError.cookieExpired` interception. No-op when `userId`
    /// doesn't match.
    public func setCookieStatus(userId: String, status: CookieStatus, at date: Date = Date()) {
        guard let idx = accounts.firstIndex(where: { $0.userId == userId }) else { return }
        accounts[idx].cookieStatus = status
        accounts[idx].cookieCheckedAt = date
        save()
    }

    /// Set or clear the group label for one account (Slope B1). Pass
    /// `nil` to remove the account from any group. Empty / whitespace
    /// strings collapse to nil so a sloppy "Add to new group…" doesn't
    /// create an invisible orphan group.
    public func setGroupName(userId: String, name: String?) {
        guard let idx = accounts.firstIndex(where: { $0.userId == userId }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts[idx].groupName = (trimmed?.isEmpty == false) ? trimmed : nil
        save()
    }

    /// Set or clear the auto-keys sequence for one account (Slope C).
    /// Pass `nil` to mark the account as not configured for auto-keys —
    /// the cycler skips it. The sequence cap (≤ 3 steps) is already
    /// enforced inside `AutoKeysSequence`'s failable initializer, so
    /// callers either pass a valid sequence or nil. No-op when `userId`
    /// doesn't match a saved account.
    /// **Deprecated as of D-4** — use `setActiveMacroId(userId:macroId:)`
    /// + `MacroStore.upsert(_:)`. The method stays for the migration
    /// path's test coverage and any one-release downgrade rollback;
    /// production UI never calls it past D-4.4.
    public func setAutoKeys(userId: String, sequence: AutoKeysSequence?) {
        guard let idx = accounts.firstIndex(where: { $0.userId == userId }) else { return }
        accounts[idx].autoKeys = sequence
        save()
    }

    /// D-4.2 — set or clear the account's active macro reference.
    /// nil reverts to "no macro" (cycler skips unless the global
    /// default applies). The macro itself lives in `MacroStore`;
    /// AccountStore just stores the id reference.
    public func setActiveMacroId(userId: String, macroId: String?) {
        guard let idx = accounts.firstIndex(where: { $0.userId == userId }) else { return }
        accounts[idx].activeMacroId = macroId
        save()
    }

    /// Cascade: when a macro is deleted from the library, every account
    /// currently pointing at it loses its `activeMacroId`. MacroStore
    /// callers invoke this after `delete(id:)` to keep the references
    /// clean.
    public func clearReferencesToMacro(id macroId: String) {
        var changed = false
        for i in accounts.indices where accounts[i].activeMacroId == macroId {
            accounts[i].activeMacroId = nil
            changed = true
        }
        if changed { save() }
    }

    /// D-4.2 — translate any pre-library `autoKeys` /
    /// `autoKeysSourceAccountId` state into the library model.
    /// Idempotent. Production calls this on app boot via
    /// `migrateAutoKeysIfNeeded()`; tests pass a test MacroStore
    /// directly.
    public func migrateAutoKeysToLibrary(via macroStore: MacroStore) {
        let outcome = AutoKeysLibraryMigrator.migrate(
            accounts: accounts,
            existingMacros: macroStore.macros
        )
        guard !outcome.createdMacros.isEmpty
              || outcome.updatedAccounts != accounts else { return }
        for macro in outcome.createdMacros {
            macroStore.upsert(macro)
        }
        accounts = outcome.updatedAccounts
        save()
    }

    /// **Deprecated as of D-4** — D-3.5 cross-account sharing
    /// references have been replaced by direct `activeMacroId` ids
    /// pointing at library macros. Use `setActiveMacroId(userId:macroId:)`
    /// instead. This method stays one release; the migrator reads
    /// pre-D-4 on-disk values and translates them.
    public func setAutoKeysSourceAccountId(userId: String, sourceUserId: String?) {
        guard let idx = accounts.firstIndex(where: { $0.userId == userId }) else { return }
        accounts[idx].autoKeysSourceAccountId = sourceUserId
        save()
    }

    /// All non-nil group names currently in use, sorted alphabetically.
    /// Drives the per-account chevron menu's "Group" submenu so users
    /// can drop an account into an existing group without retyping
    /// the name.
    public func uniqueGroupNames() -> [String] {
        let names = accounts.compactMap { $0.groupName }
        return Array(Set(names)).sorted()
    }

    /// Probe every saved account's cookie against `users.roblox.com/v1/
    /// users/authenticated`. Best-effort, off-main, fail-soft per
    /// account: a single probe failure (network glitch, 5xx) marks
    /// that account `.transient`; subsequent boots re-probe.
    ///
    /// On a healthy probe the method ALSO refreshes `displayName` and
    /// (best-effort) `avatarThumbnailURL` from the same Roblox response
    /// — Slope B2'. Display names + avatars drift between sessions
    /// (Roblox lets users change displayName freely; avatars rotate);
    /// boot-time refresh keeps the row UI honest without the user
    /// noticing a stale label. Username stays put (it's the immutable
    /// account handle).
    ///
    /// Run from `App.onAppear` so expiry + freshness signals reach
    /// the UI as early as possible.
    public func refreshAllAccounts() async {
        let snapshot = accounts
        for account in snapshot {
            let cookie = (try? cookie(for: account.userId)) ?? nil
            guard let cookie, !cookie.isEmpty else {
                continue
            }

            let status: CookieStatus
            var refreshedProfile: RobloxApi.UserProfile? = nil
            do {
                refreshedProfile = try await RobloxApi.getUserProfile(cookie: cookie)
                status = .healthy
            } catch RobloxApi.APIError.cookieExpired {
                status = .expired
            } catch {
                status = .transient
            }
            setCookieStatus(userId: account.userId, status: status)

            // Healthy → also refresh the public-profile fields. The
            // displayName from getUserProfile may differ from what we
            // last saved; updateProfile is a no-op if values match.
            if let refreshedProfile {
                updateProfile(
                    userId: account.userId,
                    displayName: refreshedProfile.displayName
                )
                // Avatar refresh is a separate Roblox endpoint — best
                // effort; soft-fails to nil. updateProfile only writes
                // when the value is non-nil so a soft-fail leaves the
                // existing avatar intact.
                if let avatarURL = try? await RobloxApi.getAvatarHeadshotURL(
                    userId: refreshedProfile.userId
                ) {
                    updateProfile(
                        userId: account.userId,
                        avatarThumbnailURL: avatarURL
                    )
                }
            }
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([Account].self, from: data) {
            accounts = decoded
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(accounts)
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // Best-effort write. A failure here means the next launch
            // won't see the updated state, but the in-memory state is
            // still good for the current session. UI can surface this
            // through DiagnosticsView (Phase 5).
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
        return dir.appendingPathComponent("accounts.json", isDirectory: false)
    }
}
