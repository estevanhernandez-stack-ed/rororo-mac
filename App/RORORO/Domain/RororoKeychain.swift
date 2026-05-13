// RororoKeychain.swift
// Domain — wrapper around /usr/bin/security for the keychain-level
// operations RororoKeychainBootstrap needs:
//   - create-keychain
//   - unlock-keychain (auto-unlock pattern: empty password)
//   - list-keychains -s (search list prepend / remove)
//   - delete-keychain
//
// Item-level operations (SecItemAdd with custom ACL) live in
// RororoKeychainItems. The two files are split so the keychain-level
// CLI work is testable in isolation from the SecAccess / csreq plumbing.
//
// The framework-level equivalents (SecKeychainCreate, SecKeychain-
// SetSearchList, etc.) are deprecated under the modern unified
// Keychain Services API; /usr/bin/security is the path Apple still
// ships and the one Raptor-Manager / Nitrogen / celestial-ui all use.
//
// Production callers use `productionPath`. Tests pass an explicit
// keychainPath so the dev's login keychain stays clean.

import Foundation

public enum RororoKeychain {

    public enum KeychainCLIError: Error, Equatable {
        case createFailed(status: Int32, stderr: String)
        case unlockFailed(status: Int32, stderr: String)
        case listKeychainsFailed(status: Int32, stderr: String)
        case setSearchListFailed(status: Int32, stderr: String)
        case deleteFailed(status: Int32, stderr: String)
    }

    /// Production keychain path. `~/Library/Keychains/RORORO.keychain-db`.
    ///
    /// **Critical:** use the `.keychain-db` form here, not `.keychain`.
    /// `security create-keychain` auto-creates the `.keychain-db` file
    /// regardless of which form you pass. But `FileManager.fileExists`
    /// against the `.keychain` form returns `false` even when the `-db`
    /// file exists. If the bootstrap's "do I need to create?" check uses
    /// the `.keychain` form, every app launch will re-create the file —
    /// wiping any items we already populated. Caught manually 2026-05-12
    /// during the live Launch-As smoke. The `.keychain-db` form makes
    /// `fileExists` honest.
    public static var productionPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/RORORO.keychain-db")
    }

    /// Create the keychain at `keychainPath` with the given password,
    /// then immediately set "never lock" settings + unlock it. Empty
    /// password is the Raptor pattern for auto-unlocking keychains.
    /// Throws if the keychain already exists at the path.
    ///
    /// The set-settings + unlock steps are bundled here because they
    /// must run BEFORE any item is added — otherwise the new item
    /// inherits the keychain's default lock-on-sleep / lock-on-idle
    /// settings and the user sees a "rororo wants to use the keychain"
    /// prompt the next time any process accesses it (caught manually
    /// 2026-05-12 during the live Launch-As smoke).
    public static func create(keychainPath: URL, password: String) throws {
        let createResult = runSecurity([
            "create-keychain", "-p", password, keychainPath.path
        ])
        if createResult.status != 0 {
            throw KeychainCLIError.createFailed(
                status: createResult.status, stderr: createResult.stderr
            )
        }
        // Settings: -t 0 = never auto-lock by timeout. Omit -l (do NOT lock
        // on sleep). `set-keychain-settings` with no flags also sets
        // no-timeout but be explicit so the contract is visible.
        let settingsResult = runSecurity([
            "set-keychain-settings", "-t", "0", keychainPath.path
        ])
        if settingsResult.status != 0 {
            throw KeychainCLIError.createFailed(
                status: settingsResult.status,
                stderr: "set-keychain-settings: \(settingsResult.stderr)"
            )
        }
        // Unlock immediately so the first item add doesn't trip on a
        // newly-locked keychain.
        try unlock(keychainPath: keychainPath, password: password)
    }

    /// Unlock the keychain. With an empty-password keychain this is a
    /// no-op the user never sees; with a passworded keychain this is
    /// where the user would be prompted (we don't use that path).
    public static func unlock(keychainPath: URL, password: String) throws {
        let result = runSecurity([
            "unlock-keychain", "-p", password, keychainPath.path
        ])
        if result.status != 0 {
            throw KeychainCLIError.unlockFailed(status: result.status, stderr: result.stderr)
        }
    }

    /// Return the current keychain search list, in order. Each entry is
    /// an absolute path. Output of `security list-keychains -d user` is
    /// one quoted path per line with leading whitespace — we strip both.
    public static func currentSearchList() throws -> [String] {
        let result = runSecurity(["list-keychains", "-d", "user"])
        if result.status != 0 {
            throw KeychainCLIError.listKeychainsFailed(
                status: result.status, stderr: result.stderr
            )
        }
        return result.stdout
            .split(separator: "\n")
            .map { line -> String in
                line
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            .filter { !$0.isEmpty }
    }

    /// Make `keychainPath` the first entry in the user's keychain search
    /// list. Preserves all existing entries. Idempotent — re-running
    /// with the same path leaves the list unchanged.
    ///
    /// Paths are resolved through the system's symlinks before insert
    /// and compare. `security list-keychains` always returns the
    /// canonical form (e.g. `/private/var/folders/...`), so a caller
    /// passing `/var/folders/...` would otherwise see a duplicate
    /// entry on every re-run.
    ///
    /// macOS REQUIRES user authorization to modify the search list;
    /// this call is what triggers the one-time password prompt at
    /// first run. Production callers run this on a background queue
    /// with the KeychainBootstrapPromptView visible so the user knows
    /// why the prompt appeared.
    public static func prependToSearchList(keychainPath: URL) throws {
        let canonical = canonicalPath(for: keychainPath)
        var list = try currentSearchList()
        list.removeAll { $0 == canonical }
        list.insert(canonical, at: 0)
        var args = ["list-keychains", "-d", "user", "-s"]
        args.append(contentsOf: list)
        let result = runSecurity(args)
        if result.status != 0 {
            throw KeychainCLIError.setSearchListFailed(
                status: result.status, stderr: result.stderr
            )
        }
    }

    /// Remove `keychainPath` from the search list if present. Used by
    /// test tearDown so test keychains don't accumulate in the search
    /// list across runs. No-op if not in the list.
    public static func removeFromSearchListIfPresent(keychainPath: URL) throws {
        let canonical = canonicalPath(for: keychainPath)
        let list = try currentSearchList()
        guard list.contains(canonical) else { return }
        let newList = list.filter { $0 != canonical }
        var args = ["list-keychains", "-d", "user", "-s"]
        args.append(contentsOf: newList)
        let result = runSecurity(args)
        if result.status != 0 {
            throw KeychainCLIError.setSearchListFailed(
                status: result.status, stderr: result.stderr
            )
        }
    }

    /// Resolve symlinks in `path` via POSIX `realpath(3)` when the file
    /// exists. When the file doesn't exist (e.g. tearDown after delete),
    /// fall back to a manual `/var → /private/var` rewrite since
    /// macOS-on-Intel + Apple-Silicon both symlink that prefix, and
    /// `security list-keychains` always returns the canonical form.
    /// Without this normalization, the contains-check in `prepend` and
    /// `remove` misses entries because Foundation's URL.resolvingSymlinks-
    /// InPath() does NOT walk the `/var → /private/var` mount on macOS.
    static func canonicalPath(for url: URL) -> String {
        let path = url.path
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        // realpath returns NULL for non-existent paths; fall back to
        // the manual rewrite for the only case that matters in tests
        // (`/var/folders/...` from NSTemporaryDirectory()).
        if path.hasPrefix("/var/") && !path.hasPrefix("/private/var/") {
            return "/private" + path
        }
        return path
    }

    /// Delete the keychain at path. Used by uninstall paths and test
    /// tearDown. No-op if the file doesn't exist.
    public static func delete(keychainPath: URL) throws {
        guard FileManager.default.fileExists(atPath: keychainPath.path) else { return }
        let result = runSecurity(["delete-keychain", keychainPath.path])
        if result.status != 0 {
            throw KeychainCLIError.deleteFailed(
                status: result.status, stderr: result.stderr
            )
        }
    }

    // MARK: - /usr/bin/security shell-out

    private struct CLIResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func runSecurity(_ args: [String]) -> CLIResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            return CLIResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        task.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return CLIResult(
            status: task.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
