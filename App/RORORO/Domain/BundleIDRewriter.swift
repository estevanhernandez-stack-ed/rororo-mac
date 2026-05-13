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
// Re-sign recipe (Nitrogen-pattern, validated by PoC 2026-05-12):
//   codesign --force --deep --sign <identity> <copy.app>
//
// Ad-hoc identity (`-`) is the default — works for end-user distribution
// without requiring a Developer ID cert in keychain. Confirmed by three
// production tools (Nitrogen, Raptor-Manager, celestial-ui) shipping ad-
// hoc re-signing to thousands of users.
//
// `--deep` re-signs every embedded binary too. Loses Roblox's Roblox-
// team signature on inner helpers, but ad-hoc-everywhere means library
// validation has nothing to enforce (no team mismatch can occur). Drops
// Hardened Runtime on the re-signed copy — accepted trade for end-user
// shipping; the cookie-isolation goal doesn't require Hardened Runtime
// on Roblox's binary specifically.
//
// History note: the prior recipe (no --deep, --options runtime, with
// disable-library-validation entitlement) worked with Developer ID
// identity but FAILED with ad-hoc identity — codesign bails on unsigned
// subcomponents (RORORO's ClientAppSettings.json FFlag injection file
// living under Contents/MacOS/ClientSettings/) when ad-hoc-signing
// without --deep. Switching to --deep fixes that AND drops the cert
// dependency for distribution.

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
    ///
    /// `entitlementsPath` is accepted for API stability but ignored by
    /// the current ad-hoc `--deep` recipe (the entitlement was useful
    /// when we tried to preserve Roblox's team signature on inner
    /// helpers; with `--deep` ad-hoc, library validation has nothing
    /// to enforce and the entitlement is moot). Kept in the signature
    /// so callers/tests don't need to change.
    public static func rewrite(
        at appURL: URL,
        newBundleID: String,
        signingIdentity: String,
        entitlementsPath: String,
        displayName: String? = nil
    ) throws {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        try editInfoPlist(at: plistURL, newBundleID: newBundleID, displayName: displayName)
        try resign(appURL: appURL, identity: signingIdentity)
    }

    private static func editInfoPlist(at plistURL: URL, newBundleID: String, displayName: String?) throws {
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
        // Set CFBundleDisplayName so macOS TCC prompts read as
        // "Roblox · <account>" instead of just the bundle filename.
        // Clearer to the user that this IS Roblox under a per-account
        // identity, not some unknown app named after their account.
        if let displayName, !displayName.isEmpty {
            plist["CFBundleDisplayName"] = "Roblox · \(displayName)"
        }

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

    private static func resign(appURL: URL, identity: String) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = [
            "--force",
            "--deep",
            "--sign", identity,
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
