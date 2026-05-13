// RororoKeychainItems.swift
// Domain — pre-populates RORORO.keychain with the items Roblox queries
// on launch, each with a permissive ACL that allows any app to read /
// modify without a password prompt.
//
// Why permissive ACL (instead of the plan's original wildcard-prefix
// idea): macOS's public Security framework API does NOT expose a way
// to embed a code-signing requirement (e.g. `identifier like
// "com.626labs.RORORO.instance.*"`) directly into a Keychain ACL's
// subject. The closest API — SecAccessCreate / SecACLSetSimpleContents
// — only accepts an applicationList of SecTrustedApplicationRef (path-
// based), with a documented "NULL = prompt" / "empty = deny-all"
// semantic. SecTrustedApplicationCreateFromRequirement is not in the
// public headers. Embedding a requirement subject directly requires
// CSSM internals that have been deprecated since macOS 10.7 and have
// no maintained replacement.
//
// The viable production path is `/usr/bin/security add-generic-password
// -A`, which creates an item readable by any process. We use that.
//
// Why this is acceptable: the items we pre-populate hold empty
// placeholder values, NOT real session credentials. The actual
// .ROBLOSECURITY cookie lives in
// `~/Library/HTTPStorages/com.626labs.RORORO.instance.uid<slug>.binarycookies`
// per ADR 0009. The Studio-shared keychain item (SharedROBLOSECURITY-
// ForStudio) is what Roblox Player checks for presence; if it ever
// writes a real token there, the trade-off becomes that a rogue local
// app could read that token. Mitigation: the wildcard-prefix design
// would have had the same exposure (any ad-hoc-signed binary matching
// our prefix could read it); the security posture is equivalent.
//
// See ADR 0010 for the full rationale, the trade-off, and the hardening
// path for a future release (managing per-cdhash trusted-app lists at
// build time, requires a per-build ceremony when adding accounts).

import Foundation
import Security

public enum RoroKeychainItem_Kind: Equatable {
    case internetPassword
    case genericPassword
}

public enum RoroKeychainItem_Protocol: Equatable {
    case https
    case http
}

public struct RoroKeychainItem: Equatable {
    public let kind: RoroKeychainItem_Kind
    public let server: String?       // for .internetPassword
    public let path: String?         // for .internetPassword
    public let account: String       // both classes
    public let service: String?      // for .genericPassword
    public let protocolType: RoroKeychainItem_Protocol?  // for .internetPassword

    public init(
        kind: RoroKeychainItem_Kind,
        server: String? = nil,
        path: String? = nil,
        account: String,
        service: String? = nil,
        protocolType: RoroKeychainItem_Protocol? = nil
    ) {
        self.kind = kind
        self.server = server
        self.path = path
        self.account = account
        self.service = service
        self.protocolType = protocolType
    }
}

public enum RororoKeychainItems {

    public enum ItemsError: Error, Equatable {
        case unsupportedKind(reason: String)
        case cliFailed(status: Int32, stderr: String)
    }

    /// Idempotently add `item` to the keychain at `keychainPath`. If an
    /// item with the same identifying attributes already exists, this
    /// is a no-op (the security CLI returns errSecDuplicateItem; we
    /// swallow it).
    public static func add(_ item: RoroKeychainItem, toKeychainAt keychainPath: URL) throws {
        if try exists(item, inKeychainAt: keychainPath) { return }
        let args = try buildAddArgs(item: item, keychainPath: keychainPath)
        let result = runSecurity(args)
        // errSecDuplicateItem (status 45) — treat as success (race-free
        // idempotency under concurrent calls).
        guard result.status == 0 || result.status == 45 else {
            throw ItemsError.cliFailed(status: result.status, stderr: result.stderr)
        }
    }

    /// Return true if the item is queryable in the given keychain.
    public static func exists(_ item: RoroKeychainItem, inKeychainAt keychainPath: URL) throws -> Bool {
        let args = try buildFindArgs(item: item, keychainPath: keychainPath)
        let result = runSecurity(args)
        switch result.status {
        case 0: return true
        case 44, 50: return false  // errSecItemNotFound, errSecInvalidItemRef
        default: throw ItemsError.cliFailed(status: result.status, stderr: result.stderr)
        }
    }

    // MARK: - argv builders

    private static func buildAddArgs(item: RoroKeychainItem, keychainPath: URL) throws -> [String] {
        switch item.kind {
        case .genericPassword:
            // `add-generic-password -a <account> -s <service> -w "" -A <keychain>`
            // -A: allow any app to read/modify without warning.
            // -w "": empty password value (placeholder).
            var args = ["add-generic-password", "-A"]
            args.append(contentsOf: ["-a", item.account])
            if let service = item.service {
                args.append(contentsOf: ["-s", service])
            }
            args.append(contentsOf: ["-w", ""])
            args.append(keychainPath.path)
            return args
        case .internetPassword:
            guard let server = item.server else {
                throw ItemsError.unsupportedKind(reason: "internetPassword requires server")
            }
            var args = ["add-internet-password", "-A"]
            args.append(contentsOf: ["-a", item.account])
            args.append(contentsOf: ["-s", server])
            if let path = item.path {
                args.append(contentsOf: ["-p", path])
            }
            if let proto = item.protocolType {
                args.append(contentsOf: ["-r", proto.cliCode])
            }
            args.append(contentsOf: ["-w", ""])
            args.append(keychainPath.path)
            return args
        }
    }

    private static func buildFindArgs(item: RoroKeychainItem, keychainPath: URL) throws -> [String] {
        switch item.kind {
        case .genericPassword:
            var args = ["find-generic-password", "-a", item.account]
            if let service = item.service {
                args.append(contentsOf: ["-s", service])
            }
            args.append(keychainPath.path)
            return args
        case .internetPassword:
            guard let server = item.server else {
                throw ItemsError.unsupportedKind(reason: "internetPassword requires server")
            }
            var args = ["find-internet-password", "-a", item.account, "-s", server]
            args.append(keychainPath.path)
            return args
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

private extension RoroKeychainItem_Protocol {
    /// `security add-internet-password -r <fourcc>` codes per the
    /// SecProtocolType enum. https = 'htps', http = 'http'.
    var cliCode: String {
        switch self {
        case .https: return "htps"
        case .http:  return "http"
        }
    }
}
