// BundleIDRewriter.swift
// Domain — rewrites a per-instance Roblox bundle copy with a unique
// CFBundleIdentifier, flips LSMultipleInstancesProhibited to false in
// the same Info.plist edit pass, then re-signs the outer .app shell
// with the supplied identity using a relaxed-library-validation
// entitlement.
//
// Why this exists: macOS keys cookies, NSUserDefaults, HTTPStorages,
// and WebKit storage by CFBundleIdentifier, not bundle path. Multi-
// instance per-account isolation requires per-instance bundle IDs.
// Editing Info.plist invalidates the bundle's cdhash; the re-sign
// recomputes it so amfid accepts the launch under Hardened Runtime.
//
// Re-sign recipe (validated by PoC 2026-05-11, see plan v2):
//   codesign --force \
//     --sign <identity> \
//     --options runtime \
//     --entitlements <relax-libval.plist> \
//     <copy.app>
//
// Three things we deliberately DON'T do:
//   - --deep: would re-sign embedded helpers and break their Roblox-
//     team-signed library validation chain.
//   - Ad-hoc identity by default in production: prior failure mode
//     (commit 95d72fe). The caller passes the identity string; for
//     shipped RORORO that's a Developer ID. Tests pass "-" because
//     library validation isn't enforced for fixture bundles.
//   - Omit the entitlement: without disable-library-validation, the
//     re-signed parent (our team) can't load Roblox-team-signed
//     embedded code under Hardened Runtime.

import Foundation

public enum BundleIDRewriter {

    public enum RewriteError: Error, Equatable {
        case entitlementsMissing(path: String)
        case infoPlistReadFailed(underlying: String)
        case infoPlistWriteFailed(underlying: String)
        case codesignFailed(status: Int32, stderr: String)
    }

    /// Mutate the bundle at `appURL` so it has a unique bundle ID,
    /// `LSMultipleInstancesProhibited=false`, and a fresh signature
    /// matching the new cdhash. Idempotent — calling twice with the
    /// same `newBundleID` re-signs the same modified plist twice.
    public static func rewrite(
        at appURL: URL,
        newBundleID: String,
        signingIdentity: String,
        entitlementsPath: String
    ) throws {
        // Pre-flight: entitlements file must exist; codesign fails
        // cryptically with a "could not parse entitlements" message
        // if the path is wrong. Check first so the error names the
        // actual problem and we don't mutate the plist before
        // discovering we can't re-sign.
        guard FileManager.default.fileExists(atPath: entitlementsPath) else {
            throw RewriteError.entitlementsMissing(path: entitlementsPath)
        }

        let plistURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        try editInfoPlist(at: plistURL, newBundleID: newBundleID)
        try resign(appURL: appURL, identity: signingIdentity, entitlementsPath: entitlementsPath)
    }

    private static func editInfoPlist(at plistURL: URL, newBundleID: String) throws {
        let data: Data
        do {
            data = try Data(contentsOf: plistURL)
        } catch {
            throw RewriteError.infoPlistReadFailed(underlying: error.localizedDescription)
        }

        var format: PropertyListSerialization.PropertyListFormat = .xml
        let obj: Any
        do {
            obj = try PropertyListSerialization.propertyList(
                from: data,
                options: .mutableContainersAndLeaves,
                format: &format
            )
        } catch {
            throw RewriteError.infoPlistReadFailed(underlying: error.localizedDescription)
        }
        guard var plist = obj as? [String: Any] else {
            throw RewriteError.infoPlistReadFailed(underlying: "Info.plist root is not a dictionary")
        }

        plist["CFBundleIdentifier"] = newBundleID
        plist["LSMultipleInstancesProhibited"] = false

        let outData: Data
        do {
            outData = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: format,
                options: 0
            )
        } catch {
            throw RewriteError.infoPlistWriteFailed(underlying: error.localizedDescription)
        }
        do {
            try outData.write(to: plistURL, options: .atomic)
        } catch {
            throw RewriteError.infoPlistWriteFailed(underlying: error.localizedDescription)
        }
    }

    private static func resign(appURL: URL, identity: String, entitlementsPath: String) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = [
            "--force",
            "--sign", identity,
            "--options", "runtime",
            "--entitlements", entitlementsPath,
            appURL.path
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        try task.run()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw RewriteError.codesignFailed(
                status: task.terminationStatus,
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
