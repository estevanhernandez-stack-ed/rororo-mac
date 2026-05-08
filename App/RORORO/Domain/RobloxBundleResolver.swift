// RobloxBundleResolver.swift
// Domain — locate the user's Roblox.app bundle on macOS.
//
// AppleBlox spike (2026-05-08) confirmed that on macOS, Roblox's
// FFlag config file lives INSIDE the .app bundle at
// `Contents/MacOS/ClientSettings/ClientAppSettings.json`. There is no
// user-Library FFlag path the player reads — the bundle is the only
// sink. This works because Roblox's own installer drops the .app
// user-writable (no admin prompt) and the binary's signature does not
// strict-validate user-data subdirectories.
//
// AppleBlox's resolver order (frontend/src/windows/main/ts/roblox/path.ts):
//   1. Spotlight `mdfind kMDItemCFBundleIdentifier == 'com.roblox.RobloxPlayer'`
//   2. Recursive `find` in /Applications then $HOME/Applications
//   3. Hardcoded fallbacks: /Applications/Roblox.app, $HOME/Applications/Roblox.app
//   - Multiple installs: most-recently-modified wins.
//   - Validation: read Info.plist via plutil, confirm bundle id starts with `com.roblox`.
//
// We mirror that posture in Swift. `mdfind` requires Process, which we
// guard with a timeout to avoid hanging the launch flow on a Spotlight
// stall. Fallbacks are pure FileManager.

import Foundation

public enum RobloxBundleResolver {

    public enum ResolverError: Error, Equatable {
        case notFound(searched: [String])
    }

    /// Try Spotlight, then `/Applications/Roblox.app`, then
    /// `~/Applications/Roblox.app`. Returns the first one whose
    /// Info.plist confirms a `com.roblox.*` bundle identifier.
    public static func resolveBundle() -> URL? {
        if let url = spotlightLookup(), validate(bundleAt: url) {
            return url
        }
        for candidate in fallbackCandidates() {
            if validate(bundleAt: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Resolve the file inside the bundle where ClientAppSettings.json
    /// lives. Returns nil if the bundle can't be located.
    public static func clientSettingsFileURL() -> URL? {
        guard let bundle = resolveBundle() else { return nil }
        return bundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("ClientSettings", isDirectory: true)
            .appendingPathComponent("ClientAppSettings.json", isDirectory: false)
    }

    /// Validate that a candidate path is actually a Roblox bundle.
    /// Reads Info.plist via PropertyListSerialization (no plutil shell-out)
    /// and confirms `CFBundleIdentifier` starts with `com.roblox`.
    public static func validate(bundleAt url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            return false
        }
        let plistURL = url
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let bundleId = plist["CFBundleIdentifier"] as? String else {
            return false
        }
        return bundleId.hasPrefix("com.roblox")
    }

    // MARK: - Internals

    /// Hardcoded fallback candidates in priority order.
    /// Internal so tests can inspect; production callers go through resolveBundle.
    static func fallbackCandidates() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications/Roblox.app", isDirectory: true),
            home.appendingPathComponent("Applications/Roblox.app", isDirectory: true),
        ]
    }

    /// Run `mdfind` with a hard timeout. On any failure (Spotlight off,
    /// Process throws, timeout), return nil so the caller falls back.
    private static func spotlightLookup(timeout: TimeInterval = 1.5) -> URL? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = [
            "kMDItemCFBundleIdentifier == 'com.roblox.RobloxPlayer'"
        ]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }

        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        let candidates = text
            .split(whereSeparator: \.isNewline)
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }

        // Multiple-installs case: pick the most-recently-modified.
        var best: (url: URL, mtime: Date)? = nil
        for candidate in candidates {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: candidate.path),
                  let mtime = attrs[.modificationDate] as? Date else {
                continue
            }
            if best == nil || mtime > best!.mtime {
                best = (candidate, mtime)
            }
        }
        return best?.url
    }
}
