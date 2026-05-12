// RobloxAppCopier.swift
// Domain — clones `/Applications/Roblox.app` into `~/Library/Application Support/RORORO/instances/<uuid>.app/`
// per launch and flips `LSMultipleInstancesProhibited = false` on the copy.
//
// Why the copy: macOS LaunchServices treats two installations of the same
// bundle ID as separate apps when their bundle paths differ. We can't run
// two of `/Applications/Roblox.app` simultaneously without surgery on the
// original (which we won't do — Roblox auto-updater would silently overwrite
// our changes anyway). Per-instance copies in our private support dir
// sidestep both problems.
//
// LSMultipleInstancesProhibited: defaults to NO when omitted, but Roblox
// ships with it set to YES. Flipping it on the copy is a hard requirement
// — without it, NSWorkspace.shared.open silently activates the existing
// instance instead of spawning a new one, even with `createsNewApplicationInstance`.
//
// Cleanup: each launch creates a ~600MB copy. We delete copies older than
// 24h on boot — anything that old is definitely from a previous session
// (Roblox processes don't survive a Mac reboot and rarely run for a full
// day). Clean-on-boot is run from a background queue; never blocks UI.
//
// Technique provenance: Insadem's `internal/robloxapp/copy_darwin.go` +
// `internal/infoplist/infoplist.go`. We reimplement here in Swift; no code
// is copied.

import Foundation

public enum RobloxAppCopier {

    /// Production path. Tests pass a custom `sourceAppPath` to `copyAppForInstance(sourceAppPath:)`
    /// against a fake .app fixture so we don't need a real Roblox install.
    public static let robloxAppPath = "/Applications/Roblox.app"

    /// Subdirectory under `~/Library/Application Support/<bundle>/` where
    /// per-instance copies live. Single canonical path so cleanup-on-boot
    /// only ever touches our own files.
    public static let instancesSubdir = "instances"

    public enum CopyError: Error, Equatable {
        case sourceMissing(path: String)
        case copyFailed(underlying: String)
        case infoPlistReadFailed(underlying: String)
        case infoPlistWriteFailed(underlying: String)
        case supportDirCreationFailed(underlying: String)
    }

    /// Resolve `~/Applications/RORORO/instances/`. Creates the directory
    /// tree if missing. Throws on filesystem failure.
    ///
    /// Why `~/Applications/` and not `~/Library/Application Support/`:
    /// macOS Gatekeeper treats anything under `Library/` with extra
    /// scrutiny — running a `.app` from there triggers a "Verifying"
    /// progress bar that can stall (caught at v0.1.2 manual smoke,
    /// 2026-05-07). `~/Applications/` is the user's personal apps folder
    /// and gets standard Gatekeeper treatment. The Insadem reference uses
    /// `~/Library/Caches/` and works on older macOS, but newer macOS
    /// (14+) is stricter.
    public static func instancesRoot(supportDirOverride: URL? = nil) throws -> URL {
        let support: URL
        if let supportDirOverride {
            support = supportDirOverride
        } else {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            let userApps = homeDir.appendingPathComponent("Applications", isDirectory: true)
            // Namespace under the bundle name so multiple 626 Labs apps
            // don't collide.
            support = userApps.appendingPathComponent("RORORO", isDirectory: true)
        }
        let instances = support.appendingPathComponent(instancesSubdir, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: instances, withIntermediateDirectories: true)
        } catch {
            throw CopyError.supportDirCreationFailed(underlying: error.localizedDescription)
        }
        return instances
    }

    /// Build a per-instance bundle ID. **Pass a stable `accountSlug`
    /// whenever account context is available** (the normal Launch As
    /// path passes `account.userId`). Stable bundle IDs:
    ///
    ///   - keep macOS's TCC grants attached across launches (local
    ///     network, camera, mic, etc. prompt once per account, not on
    ///     every click);
    ///   - let `RunningAccountTracker` match a per-instance bundle ID
    ///     back to its Roblox account on cold-start backfill.
    ///
    /// `accountSlug == nil` (or empty after slugify) falls back to a
    /// fresh UUID — used by the rare URL-handoff path where there's no
    /// account context. That path re-prompts TCC each launch, but it's
    /// rare enough to be acceptable.
    public static func makePerInstanceBundleID(accountSlug: String? = nil) -> String {
        if let accountSlug, !accountSlug.isEmpty {
            let safe = slugifyForBundleID(accountSlug)
            if !safe.isEmpty {
                return "com.626labs.RORORO.instance.uid\(safe)"
            }
        }
        return "com.626labs.RORORO.instance.\(UUID().uuidString.lowercased())"
    }

    /// Lowercase + restrict to `[a-z0-9-]` (the safe subset for reverse-
    /// DNS bundle ID components). Other characters become `-`; runs of
    /// `-` collapse; leading/trailing `-` are stripped.
    private static func slugifyForBundleID(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let lowered = raw.lowercased()
        let mapped = String(lowered.map { allowed.contains($0) ? $0 : "-" })
        // Collapse runs of "-" and trim leading/trailing.
        var collapsed = ""
        var lastWasDash = false
        for ch in mapped {
            if ch == "-" {
                if !lastWasDash { collapsed.append(ch) }
                lastWasDash = true
            } else {
                collapsed.append(ch)
                lastWasDash = false
            }
        }
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Path to the bundled re-sign entitlements file inside RORORO.app
    /// (`Contents/Resources/roblox-resign.plist`). Returns nil if the
    /// resource is missing — caller throws on nil so production code never
    /// silently skips the re-sign.
    public static func defaultEntitlementsPath() -> String? {
        return Bundle.main.path(forResource: "roblox-resign", ofType: "plist")
    }

    /// Default signing identity for runtime re-sign. Ad-hoc (`-`) — works
    /// on any user's machine without requiring a Developer ID cert in
    /// keychain. Matches the Nitrogen / Raptor-Manager / celestial-ui
    /// production pattern (validated Task 4.5 PoC 2026-05-12). The
    /// `BundleIDRewriter.rewrite` recipe uses `--deep` so library
    /// validation has nothing to enforce; ad-hoc-everywhere is self-
    /// consistent. Drops Hardened Runtime on the re-signed copy —
    /// accepted trade-off for end-user distribution.
    public static func defaultSigningIdentity() -> String {
        return "-"
    }

    /// Copy `/Applications/Roblox.app` into `instances/<uuid>/<label>.app/`,
    /// rewrite the copy's `CFBundleIdentifier` to a unique
    /// `com.626labs.RORORO.instance.<uuid>`, flip
    /// `LSMultipleInstancesProhibited` to false in the same Info.plist
    /// pass, and re-sign the outer .app shell so the new cdhash matches.
    /// Returns the copy URL — ready for `open -n -a` to launch.
    ///
    /// Why the rewrite happens here: macOS keys cookies / NSUserDefaults /
    /// HTTPStorages / WebKit storage by `CFBundleIdentifier`, not bundle
    /// path. Per-instance bundle IDs deliver per-instance isolation
    /// natively (see ADR 0009). The re-sign is required because plist
    /// edits invalidate the bundle's cdhash; without a fresh signature,
    /// amfid would refuse the spawn under Hardened Runtime.
    ///
    /// Caller flow:
    ///   1. let copy = copyAppForInstance()        // rewritten + re-signed
    ///   2. SemaphoreBreaker.breakRobloxSingleton()
    ///   3. open -n -a <copy> <url>                 // launches with new cdhash
    ///   4. SemaphoreBreaker.breakRobloxSingleton() // race buffer
    /// Sanitize a free-form display string into a filename-safe bundle
    /// label. Forbidden HFS+/APFS character `/` becomes `-`; trims
    /// whitespace; caps length so the Dock doesn't elide the back of
    /// the name. Empty / nil input returns the default `Roblox`.
    public static func sanitizedBundleLabel(from raw: String?) -> String {
        guard let raw else { return "Roblox" }
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return "Roblox" }
        return String(cleaned.prefix(48))
    }

    public static func copyAppForInstance(
        sourceAppPath: String = robloxAppPath,
        supportDirOverride: URL? = nil,
        bundleLabel: String? = nil,
        accountSlug: String? = nil,
        signingIdentity: String? = nil,
        entitlementsPath: String? = nil
    ) throws -> URL {
        // Validate source. Use directoryExists semantics — `.app` is a directory.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: sourceAppPath, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw CopyError.sourceMissing(path: sourceAppPath)
        }

        // Compute destination. Each launch gets a fresh UUID PARENT
        // directory; the bundle inside is named after the launching
        // account (or `Roblox` when no account context is available).
        // macOS Dock displays the bundle's basename when CFBundleName-
        // based dedup ties; using the account display name as the
        // bundle name means each multi-instance Dock entry self-labels
        // (caught by user observation 2026-05-08: "the bottom bar had
        // numbers instead of names for each roblox window" → "could
        // you nest it in the players name instead").
        let instancesURL = try instancesRoot(supportDirOverride: supportDirOverride)
        let parentDir = instancesURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        } catch {
            throw CopyError.supportDirCreationFailed(underlying: error.localizedDescription)
        }
        let label = Self.sanitizedBundleLabel(from: bundleLabel)
        let destURL = parentDir.appendingPathComponent("\(label).app", isDirectory: true)

        let sourceURL = URL(fileURLWithPath: sourceAppPath, isDirectory: true)

        // FileManager.copyItem preserves the bundle structure — equivalent
        // to `cp -a` per the Insadem reference. Extended attributes,
        // resource forks, executable bits all survive.
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw CopyError.copyFailed(underlying: error.localizedDescription)
        }

        // Strip any inherited quarantine xattr.
        try removeQuarantine(at: destURL)

        // Resolve the re-sign inputs. Production callers pass nil and we
        // fall back to the host RORORO.app's bundled entitlements + our
        // Developer ID identity; tests inject ad-hoc + a temp entitlements
        // path because CI keychains don't have the Developer ID cert.
        let identity = signingIdentity ?? Self.defaultSigningIdentity()
        guard let resolvedEntitlements = entitlementsPath ?? Self.defaultEntitlementsPath() else {
            throw CopyError.copyFailed(
                underlying: "roblox-resign.plist missing from RORORO.app bundle; rebuild may have skipped resources"
            )
        }

        do {
            try BundleIDRewriter.rewrite(
                at: destURL,
                newBundleID: Self.makePerInstanceBundleID(accountSlug: accountSlug),
                signingIdentity: identity,
                entitlementsPath: resolvedEntitlements
            )
        } catch {
            throw CopyError.copyFailed(
                underlying: "bundle ID rewrite / re-sign failed: \(error.localizedDescription)"
            )
        }

        return destURL
    }

    /// Remove instance copies older than `olderThan` seconds (default 24h).
    /// Run from a background queue at boot — never blocks UI.
    public static func cleanupStaleInstances(
        olderThan: TimeInterval = 86_400,
        supportDirOverride: URL? = nil
    ) throws {
        let root = try instancesRoot(supportDirOverride: supportDirOverride)
        let cutoff = Date().addingTimeInterval(-olderThan)

        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.creationDateKey])
            if let created = values?.creationDate, created < cutoff {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    /// Strip `com.apple.quarantine` xattr from the copy. Quarantine can
    /// attach to copies (Apple's Gatekeeper marks files written by user-
    /// space code in some configs); removing it pre-launch avoids the
    /// "downloaded from internet" prompt for a copy the user never saw.
    private static func removeQuarantine(at appURL: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-dr", "com.apple.quarantine", appURL.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        // xattr exits 1 if the attribute doesn't exist — that's fine,
        // not a failure. We just don't surface it.
        try? task.run()
        task.waitUntilExit()
    }

}
