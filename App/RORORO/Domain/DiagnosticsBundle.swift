// DiagnosticsBundle.swift
// Domain — assembles a .zip of operational state + recent logs for bug
// reports. Matches the contents documented in DiagnosticsView's
// "Save bundle…" affordance:
//
//   diagnostics.txt        the structured text dump (same as Copy)
//   accounts.json          accounts.json verbatim (cookies live in
//                          Keychain, never in this file)
//   favorites.json         favorites.json verbatim — no secrets
//   private-servers.json   codes redacted to "<REDACTED>" (share-link
//                          tokens are session-class)
//   system-info.txt        macOS version, RORORO version, Roblox.app
//                          version (from /Applications/Roblox.app/Info.plist)
//   recent-logs.txt        last 1h of `log show --process RORORO`
//   url-scheme-handler.txt current handler bundle ID + saved-previous
//
// The bundle assembler runs off-main (Process calls + zip take a beat);
// the caller hops back to MainActor when the .zip is ready to surface
// success/failure.

import AppKit
import Foundation

public enum DiagnosticsBundle {

    public enum BundleError: Error, Equatable {
        case zipFailed(String)
        case writeFailed(String)
    }

    /// Build the diagnostics bundle, write it to `destURL` (which should
    /// have a `.zip` extension), and return `destURL` on success.
    /// Off-main — the assembler shells out to `/usr/bin/log` and
    /// `/usr/bin/zip`, both of which can take a few seconds.
    public static func writeBundle(to destURL: URL) async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rororo-diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // Structured text dump — built off the same data the Copy button
        // renders. Captured from a MainActor hop so we read consistent
        // singleton state.
        let textDump = await MainActor.run { buildTextDump() }
        try writeString(textDump, to: workDir.appendingPathComponent("diagnostics.txt"))

        // accounts.json + favorites.json: copy verbatim from disk if
        // present. Both files contain only public profile data — cookies
        // live in Keychain.
        let supportDir = applicationSupportDir()
        copyIfPresent(
            from: supportDir.appendingPathComponent("accounts.json"),
            to: workDir.appendingPathComponent("accounts.json")
        )
        copyIfPresent(
            from: supportDir.appendingPathComponent("favorites.json"),
            to: workDir.appendingPathComponent("favorites.json")
        )

        // Private-servers redaction: codes are session-class secrets.
        try writePrivateServersRedacted(
            from: supportDir.appendingPathComponent("private-servers.json"),
            to: workDir.appendingPathComponent("private-servers.json")
        )

        // System info — quick to compute, includes /Applications/Roblox.app
        // version so we can correlate Roblox-version-specific bugs.
        let systemInfo = await MainActor.run { buildSystemInfo() }
        try writeString(systemInfo, to: workDir.appendingPathComponent("system-info.txt"))

        // Recent system logs filtered to the RORORO process. 1h is the
        // default — bugs are usually reported within minutes of seeing
        // them, but the recent reproduction is what matters.
        let logs = await fetchRecentLogs()
        try writeString(logs, to: workDir.appendingPathComponent("recent-logs.txt"))

        // URL scheme handler state — useful when investigating why URL
        // routing landed on the wrong app.
        let schemeHandler = await MainActor.run { buildSchemeHandlerInfo() }
        try writeString(schemeHandler, to: workDir.appendingPathComponent("url-scheme-handler.txt"))

        // Pack it all up. Existing dest is removed first so we don't
        // append to a stale archive.
        try? FileManager.default.removeItem(at: destURL)
        try zipDirectoryContents(at: workDir, to: destURL)
    }

    // MARK: - Text builders

    @MainActor
    private static func buildTextDump() -> String {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let state = MultiInstanceState.shared
        let robloxInstalled = FileManager.default.fileExists(atPath: RobloxAppCopier.robloxAppPath)
        let compat = RobloxCompatStore.shared

        var lines: [String] = []
        lines.append("=== RORORO Diagnostics ===")
        lines.append("Version: \(version) (\(build))")
        lines.append("Roblox installed: \(robloxInstalled ? "Yes" : "No") at \(RobloxAppCopier.robloxAppPath)")
        lines.append("Multi-instance enabled: \(state.enabled)")
        lines.append("Successful launches this session: \(state.instanceCount)")
        lines.append("URL scheme handler claimed: \(URLSchemeHandler.shared.isClaimed)")
        lines.append("Effective semaphore: \(compat.currentSemaphoreName())")
        lines.append("Compat feed: \(compat.freshness())")
        if let err = compat.lastFetchError {
            lines.append("Compat fetch error: \(err)")
        }
        lines.append("Last error:")
        lines.append(state.lastError ?? "(none)")
        return lines.joined(separator: "\n") + "\n"
    }

    @MainActor
    private static func buildSystemInfo() -> String {
        let processInfo = ProcessInfo.processInfo
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        var lines: [String] = []
        lines.append("RORORO version: \(version) (\(build))")
        lines.append("macOS: \(processInfo.operatingSystemVersionString)")
        lines.append("Hostname: \(processInfo.hostName)")
        lines.append("Locale: \(Locale.current.identifier)")
        if let robloxVersion = readRobloxVersion() {
            lines.append("Roblox.app version: \(robloxVersion)")
        } else {
            lines.append("Roblox.app version: (not installed or unreadable)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    @MainActor
    private static func buildSchemeHandlerInfo() -> String {
        var lines: [String] = []
        lines.append("Claimed for `roblox-player://`: \(URLSchemeHandler.shared.isClaimed)")
        if let current = URLSchemeHandler.shared.currentDefaultHandlerBundleID() {
            lines.append("Current handler bundle ID: \(current)")
        } else {
            lines.append("Current handler bundle ID: (none)")
        }
        if let saved = UserDefaults.standard.string(forKey: URLSchemeHandler.savedHandlerKey) {
            lines.append("Saved-previous handler (will restore on quit): \(saved)")
        } else {
            lines.append("Saved-previous handler: (none — first claim, or already restored)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func readRobloxVersion() -> String? {
        let plistURL = URL(fileURLWithPath: RobloxAppCopier.robloxAppPath)
            .appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        let short = plist["CFBundleShortVersionString"] as? String
        let build = plist["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?): return "\(s) (\(b))"
        case let (s?, nil): return s
        case let (nil, b?): return "build \(b)"
        default: return nil
        }
    }

    // MARK: - Redaction

    private static func writePrivateServersRedacted(from src: URL, to dest: URL) throws {
        guard let data = try? Data(contentsOf: src) else { return }  // nothing to redact
        guard var json = try? JSONSerialization.jsonObject(with: data, options: [.mutableContainers]) as? [String: Any] else {
            // Unparseable — drop a placeholder.
            try writeString(
                "(private-servers.json present but unparseable; redacted from diagnostics bundle)\n",
                to: dest
            )
            return
        }
        if var servers = json["servers"] as? [[String: Any]] {
            for i in servers.indices {
                servers[i]["code"] = "<REDACTED>"
            }
            json["servers"] = servers
        }
        let redacted = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try redacted.write(to: dest)
    }

    // MARK: - log show

    private static func fetchRecentLogs() async -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = [
            "show",
            "--predicate", "process == \"RORORO\"",
            "--last", "1h",
            "--style", "syslog",
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? "(unreadable log output)"
            if task.terminationStatus != 0 {
                return "log show exited \(task.terminationStatus)\n\n\(output)"
            }
            return output
        } catch {
            return "log show failed to launch: \(error.localizedDescription)"
        }
    }

    // MARK: - zip

    private static func zipDirectoryContents(at source: URL, to dest: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // -j strips paths so the archive is flat (filenames at the root).
        // -r recurses (in case we add subdirs later). We use `.` from the
        // source dir so all sibling files get bundled.
        task.arguments = ["-r", dest.path, "."]
        task.currentDirectoryURL = source
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            throw BundleError.zipFailed(error.localizedDescription)
        }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "exit \(task.terminationStatus)"
            throw BundleError.zipFailed(msg)
        }
    }

    // MARK: - File helpers

    private static func writeString(_ s: String, to url: URL) throws {
        do {
            try s.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw BundleError.writeFailed(error.localizedDescription)
        }
    }

    private static func copyIfPresent(from src: URL, to dest: URL) {
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        try? FileManager.default.copyItem(at: src, to: dest)
    }

    private static func applicationSupportDir() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("RORORO", isDirectory: true)
    }
}
