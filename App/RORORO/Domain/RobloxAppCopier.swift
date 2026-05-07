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
        case adhocSignFailed(underlying: String)
    }

    /// Resolve `~/Library/Application Support/RORORO/instances/`. Creates
    /// the directory tree if missing. Throws on filesystem failure.
    public static func instancesRoot(supportDirOverride: URL? = nil) throws -> URL {
        let support: URL
        if let supportDirOverride {
            support = supportDirOverride
        } else {
            let asUrl = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            // Namespace under the bundle name so multiple 626 Labs apps
            // don't collide in Application Support.
            support = asUrl.appendingPathComponent("RORORO", isDirectory: true)
        }
        let instances = support.appendingPathComponent(instancesSubdir, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: instances, withIntermediateDirectories: true)
        } catch {
            throw CopyError.supportDirCreationFailed(underlying: error.localizedDescription)
        }
        return instances
    }

    /// Copy `/Applications/Roblox.app` into `instances/<uuid>.app/`, flip
    /// `LSMultipleInstancesProhibited`, and return the copy URL. Caller is
    /// responsible for handing the copy to NSWorkspace + `roblox-player:`
    /// URL via MultiInstanceCoordinator's recipe.
    public static func copyAppForInstance(
        sourceAppPath: String = robloxAppPath,
        supportDirOverride: URL? = nil
    ) throws -> URL {
        // Validate source. Use directoryExists semantics — `.app` is a directory.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: sourceAppPath, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw CopyError.sourceMissing(path: sourceAppPath)
        }

        // Compute destination. Each launch gets a fresh UUID.
        let instancesURL = try instancesRoot(supportDirOverride: supportDirOverride)
        let destURL = instancesURL.appendingPathComponent("\(UUID().uuidString).app", isDirectory: true)

        let sourceURL = URL(fileURLWithPath: sourceAppPath, isDirectory: true)

        // FileManager.copyItem preserves the bundle structure — equivalent
        // to `cp -a` per the Insadem reference. Extended attributes,
        // resource forks, executable bits all survive.
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw CopyError.copyFailed(underlying: error.localizedDescription)
        }

        // Flip LSMultipleInstancesProhibited on the copy's Info.plist.
        let plistURL = destURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        try flipMultipleInstancesProhibited(at: plistURL)

        // Editing Info.plist invalidated the original code signature.
        // Gatekeeper refuses to launch a modified signed app — the user
        // sees "The application '<uuid>.app' can't be opened." Re-sign
        // ad-hoc (no developer cert needed; the user is explicitly
        // launching from our private support dir) and strip any
        // inherited quarantine xattr so the launch is clean.
        try removeQuarantine(at: destURL)
        try resignAdHoc(at: destURL)

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

    /// Re-sign the copy with an ad-hoc signature (`-` identity).
    /// Ad-hoc signing is enough for Gatekeeper to launch a user-installed
    /// app from a non-system path. The user is explicitly launching from
    /// our controlled `~/Library/Application Support/RORORO/instances/`,
    /// so we don't need a Developer ID cert here.
    private static func resignAdHoc(at appURL: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        // --deep walks nested binaries (Roblox bundles helpers + frameworks);
        // --force replaces the existing (now-broken) Apple signature.
        task.arguments = ["--force", "--deep", "--sign", "-", appURL.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            throw CopyError.adhocSignFailed(underlying: error.localizedDescription)
        }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "exit \(task.terminationStatus)"
            throw CopyError.adhocSignFailed(underlying: msg)
        }
    }

    private static func flipMultipleInstancesProhibited(at plistURL: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: plistURL)
        } catch {
            throw CopyError.infoPlistReadFailed(underlying: error.localizedDescription)
        }

        var format: PropertyListSerialization.PropertyListFormat = .xml
        let plistObject: Any
        do {
            plistObject = try PropertyListSerialization.propertyList(
                from: data,
                options: .mutableContainersAndLeaves,
                format: &format
            )
        } catch {
            throw CopyError.infoPlistReadFailed(underlying: error.localizedDescription)
        }
        guard var plist = plistObject as? [String: Any] else {
            throw CopyError.infoPlistReadFailed(underlying: "Info.plist root is not a dictionary")
        }

        plist["LSMultipleInstancesProhibited"] = false

        let outData: Data
        do {
            outData = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: format,
                options: 0
            )
        } catch {
            throw CopyError.infoPlistWriteFailed(underlying: error.localizedDescription)
        }
        do {
            try outData.write(to: plistURL, options: .atomic)
        } catch {
            throw CopyError.infoPlistWriteFailed(underlying: error.localizedDescription)
        }
    }
}
