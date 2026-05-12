// RororoKeychainBootstrap.swift
// Domain — single-entry-point orchestrator for the one-time keychain
// setup that eliminates Roblox-on-launch password prompts.
//
// On first invocation per machine:
//   1. Create RORORO.keychain at the production path (empty password →
//      auto-unlocking, no future user-facing unlock prompts).
//   2. Unlock it.
//   3. Prepend to the user's keychain search list. *This step* triggers
//      a one-time macOS password prompt (system rule for search-list
//      modification). The KeychainBootstrapPromptView wraps it with
//      explanatory UI.
//   4. Pre-populate with the items in RoblxKeychainProbeList (placeholder
//      generic-password entries that Roblox queries on launch, ACL = allow
//      any app via the security CLI `-A` flag — see RororoKeychainItems
//      header for why this is the workable production path).
//   5. Mark RororoKeychainBootstrap.currentVersion in UserDefaults so
//      subsequent calls become no-ops.
//
// Bumping `currentVersion` after adding new items to RoblxKeychainProbeList
// causes the next launch to re-run population (each add is idempotent).
//
// Threading: ensureIfNeeded() blocks on user prompts during step 3. Run
// from a background task. The MultiInstanceCoordinator wraps the call
// in Task.detached(priority: .userInitiated) so the boot path never
// blocks. The KeychainBootstrapPromptView also wraps the call so the
// user sees an explanation before the macOS prompt fires.
//
// Crash recovery: each step is idempotent. A crash between steps 1 and
// 3 leaves the keychain file present but search-list-add not done; the
// next ensureIfNeeded picks up at step 2 (unlock is idempotent), runs
// step 3 (idempotent — re-prepend with same path is a no-op), proceeds.
// The version marker only flips after the full sequence completes.

import Foundation

public enum RororoKeychainBootstrap {

    /// Bump when RoblxKeychainProbeList.items grows. The bump triggers a
    /// re-populate pass on next launch — each `RororoKeychainItems.add`
    /// is idempotent, so this is safe to re-run unconditionally.
    public static let currentVersion = 1

    /// UserDefaults key the marker is stored under. Stable across renames.
    public static let versionKey = "RororoKeychainBootstrapVersion"

    public enum BootstrapError: Error, Equatable {
        case createFailed(underlying: String)
        case unlockFailed(underlying: String)
        case searchListFailed(underlying: String)
        case populateFailed(underlying: String)
    }

    /// Run the bootstrap if not already complete at `currentVersion`.
    /// Safe to call multiple times — no-op when the marker is current.
    ///
    /// Parameters exist for tests; production callers use the defaults.
    public static func ensureIfNeeded(
        keychainPath: URL = RororoKeychain.productionPath,
        probeItems: [RoroKeychainItem] = RoblxKeychainProbeList.items,
        defaults: UserDefaults = .standard
    ) async throws {
        let storedVersion = defaults.integer(forKey: versionKey)
        if storedVersion >= currentVersion { return }

        // Step 1 — create if missing. The file is the persistent indicator
        // that step 1 ran; a stray crash before any later step leaves it
        // and the next ensureIfNeeded picks up from step 2.
        if !FileManager.default.fileExists(atPath: keychainPath.path) {
            do {
                try RororoKeychain.create(keychainPath: keychainPath, password: "")
            } catch {
                throw BootstrapError.createFailed(underlying: "\(error)")
            }
        }

        // Step 2 — unlock. Idempotent (empty-password keychains auto-unlock
        // on first access; this is a belt-and-suspenders confirm).
        do {
            try RororoKeychain.unlock(keychainPath: keychainPath, password: "")
        } catch {
            throw BootstrapError.unlockFailed(underlying: "\(error)")
        }

        // Step 3 — prepend to search list. The one-time macOS password
        // prompt fires here. KeychainBootstrapPromptView is up.
        do {
            try RororoKeychain.prependToSearchList(keychainPath: keychainPath)
        } catch {
            throw BootstrapError.searchListFailed(underlying: "\(error)")
        }

        // Step 4 — populate items. Each .add is idempotent; we tolerate
        // a partial state from a prior crashed run.
        for item in probeItems {
            do {
                try RororoKeychainItems.add(item, toKeychainAt: keychainPath)
            } catch {
                throw BootstrapError.populateFailed(underlying: "\(error)")
            }
        }

        // Step 5 — mark complete. Only happens after every prior step
        // succeeded; partial runs leave the marker unset and re-run
        // (idempotently) on next ensureIfNeeded.
        defaults.set(currentVersion, forKey: versionKey)
    }

    /// True if `ensureIfNeeded` would do work. The app shell uses this to
    /// decide whether to surface KeychainBootstrapPromptView.
    public static func needsOnboarding(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.integer(forKey: versionKey) < currentVersion
    }
}
