// KeychainStore.swift
// Domain — thin wrapper around `Security.framework`'s SecItem* generic-password
// API. All Roblox `.ROBLOSECURITY` cookies live in the user's login Keychain;
// nothing else writes to disk. Same posture as RORORO Windows (which uses DPAPI).
//
// Attribute choices:
//   - kSecClassGenericPassword          — opaque blob keyed by service+account
//   - kSecAttrAccessibleWhenUnlocked    — readable only while the user is
//                                          actively logged in (no background
//                                          access while the screen is locked)
//   - kSecAttrSynchronizable: false     — never sync to iCloud Keychain. The
//                                          cookie is a session credential
//                                          tied to the local machine; it
//                                          should not roam.
//
// Test seam: `inMemoryOverride` redirects all calls to a dictionary keyed
// `"<service>::<account>"`. AccountStoreTests + KeychainStoreTests set this
// in `setUp` and clear in `tearDown` to avoid polluting the developer's
// Keychain. Production callers leave the override nil.

import Foundation
import Security

public enum KeychainStore {

    /// Default Keychain service for Roblox account cookies. AccountStore
    /// passes this; tests pass per-test unique services.
    public static let cookieService = "com.626labs.rororo-mac.account-cookie"

    public enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case dataEncodingFailed
    }

    /// Test seam. When non-nil, all calls operate on this in-memory dict
    /// keyed `"<service>::<account>"` and the real Keychain is never
    /// touched. `nonisolated(unsafe)` mirrors macRo's `LibraryStore`
    /// `urlSessionForTesting` pattern — single-writer test setUp/tearDown
    /// is the only mutator.
    nonisolated(unsafe) public static var inMemoryOverride: [String: String]?

    /// Insert or update a credential. Idempotent over re-saves.
    public static func set(service: String, account: String, value: String) throws {
        if inMemoryOverride != nil {
            inMemoryOverride?[overrideKey(service: service, account: account)] = value
            return
        }

        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataEncodingFailed
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]

        // Try update first. A nonexistent item returns errSecItemNotFound;
        // fall through to add. Splitting update+add (vs always-add-or-delete)
        // preserves any creation-date / access-list metadata Keychain
        // attached to the existing entry on first write.
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break  // fall through to add
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    /// Retrieve a credential. Returns nil for missing items; throws on
    /// any other status. Strings are stored as UTF-8.
    public static func get(service: String, account: String) throws -> String? {
        if inMemoryOverride != nil {
            return inMemoryOverride?[overrideKey(service: service, account: account)]
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                return nil
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Remove a credential. No-op on missing items; throws on other errors.
    public static func delete(service: String, account: String) throws {
        if inMemoryOverride != nil {
            inMemoryOverride?.removeValue(forKey: overrideKey(service: service, account: account))
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private static func overrideKey(service: String, account: String) -> String {
        "\(service)::\(account)"
    }
}
