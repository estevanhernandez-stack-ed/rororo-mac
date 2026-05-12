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

    /// Production keychain path. `~/Library/Keychains/RORORO.keychain`.
    /// macOS auto-migrates to the `.keychain-db` variant on first unlock;
    /// the security CLI resolves both forms identically, so callers
    /// always reference the `.keychain` form here.
    public static var productionPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/RORORO.keychain")
    }

    /// Create the keychain at `keychainPath` with the given password.
    /// Empty password → auto-unlocking keychain that never prompts for
    /// unlock again (the pattern Raptor uses for its per-profile
    /// keychains). Throws if the keychain already exists at the path.
    public static func create(keychainPath: URL, password: String) throws {
        let result = runSecurity([
            "create-keychain", "-p", password, keychainPath.path
        ])
        if result.status != 0 {
            throw KeychainCLIError.createFailed(status: result.status, stderr: result.stderr)
        }
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
    /// macOS REQUIRES user authorization to modify the search list;
    /// this call is what triggers the one-time password prompt at
    /// first run. Production callers run this on a background queue
    /// with the KeychainBootstrapPromptView visible so the user knows
    /// why the prompt appeared.
    public static func prependToSearchList(keychainPath: URL) throws {
        var list = try currentSearchList()
        list.removeAll { $0 == keychainPath.path }
        list.insert(keychainPath.path, at: 0)
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
        let list = try currentSearchList()
        guard list.contains(keychainPath.path) else { return }
        let newList = list.filter { $0 != keychainPath.path }
        var args = ["list-keychains", "-d", "user", "-s"]
        args.append(contentsOf: newList)
        let result = runSecurity(args)
        if result.status != 0 {
            throw KeychainCLIError.setSearchListFailed(
                status: result.status, stderr: result.stderr
            )
        }
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
