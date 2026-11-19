// RobloxVersionGate.swift
// Domain — refuses the multi-instance copy step while /Applications/
// Roblox.app is behind Roblox's live MacPlayer version.
//
// Why this exists (support case 2026-09-13, reproduced locally the same
// day with a 0.726 install against a 0.738 live version):
//
//   1. Every per-instance copy is a byte-for-byte clone of the stale
//      /Applications/Roblox.app, so every copy's RobloxPlayer decides it
//      needs an update and spawns its embedded RobloxPlayerInstaller.app.
//   2. The installer holds a per-user single-instance flock at
//      `$TMPDIR/com.roblox.player.installer.lock`. It is keyed by the
//      product ("player"), not the bundle ID, so our unique per-instance
//      bundle IDs don't help — the second copy's installer fails on the
//      lock and shows "Another Installer is already running."
//   3. The first copy's installer downloads the new build, moves it to
//      /Applications/Roblox.app, and relaunches THAT bundle with
//      `-isInstallerLaunch true` — the canonical single-instance app, not
//      the per-instance copy. The account identity and the launch URL
//      the user asked for are gone.
//
// None of that is fixable from inside the copy; the only clean move is
// to not copy a stale bundle. The gate compares the local
// CFBundleShortVersionString against clientsettingscdn's MacPlayer
// version and tells the user the one action that fixes it: open Roblox
// once and let it update. Multi-instance OFF launches the canonical app
// directly, which self-updates fine, so the gate only guards the copy
// path.
//
// Fail-open by design: no network / endpoint down → `.unknown` → launch
// proceeds. A blocked launch on a flaky connection would be a worse
// regression than the occasional installer dialog.

import Foundation

public actor RobloxVersionGate {

    public static let shared = RobloxVersionGate(appPath: RobloxAppCopier.robloxAppPath)

    /// Roblox's public version endpoint for the Mac player. Same call
    /// RobloxPlayerInstaller makes (`/v2/client-version/{binaryType}`).
    public static let liveVersionURL = URL(
        string: "https://clientsettingscdn.roblox.com/v2/client-version/MacPlayer"
    )!

    /// Test seam mirroring `RobloxApi.urlSessionForTesting`.
    nonisolated(unsafe) public static var urlSessionForTesting: URLSession?

    public struct LiveVersionResponse: Codable, Equatable, Sendable {
        public let version: String
        public let clientVersionUpload: String?
    }

    public enum Verdict: Equatable, Sendable {
        /// Local and live versions match — safe to copy.
        case current
        /// Local bundle is behind (or otherwise differs from) live.
        case stale(local: String, live: String)
        /// Couldn't decide — Roblox not installed, endpoint unreachable,
        /// or malformed response. Callers proceed.
        case unknown

        /// User-facing copy for the stale case; nil otherwise.
        public var userMessage: String? {
            guard case .stale(let local, let live) = self else { return nil }
            return "Roblox needs an update before multi-instance can launch "
                + "(installed \(local), current \(live)). Open Roblox once from "
                + "/Applications, let it update, then try Launch As again."
        }
    }

    private let appPath: String
    private let cacheTTL: TimeInterval
    nonisolated(unsafe) private let defaults: UserDefaults
    private var cachedLive: (version: String, fetchedAt: Date)?

    /// `cacheTTL` bounds how often the live version is re-fetched. A
    /// group launch of N accounts should cost one request, not N.
    public init(appPath: String, cacheTTL: TimeInterval = 300, defaults: UserDefaults = .standard) {
        self.appPath = appPath
        self.cacheTTL = cacheTTL
        self.defaults = defaults
    }

    // MARK: - Pure pieces

    /// Stale only when local is numerically BEHIND live. A local build
    /// ahead of live (a beta channel, or a CDN that hasn't caught up) is
    /// not something opening Roblox can fix, so it counts as current.
    /// A (local, live) pair Roblox has already declined to update counts
    /// as current too; see `declinedPair`.
    public nonisolated static func verdict(
        local: String?,
        live: String?,
        declined: (local: String, live: String)? = nil
    ) -> Verdict {
        guard let local, let live else { return .unknown }
        if let declined, declined.local == local, declined.live == live { return .current }
        return isBehind(local, live) ? .stale(local: local, live: live) : .current
    }

    /// Component-wise numeric compare of dotted builds
    /// (`0.726.0.7261140` < `0.738.0.7381393`). Missing components are 0.
    /// A non-numeric component falls back to string inequality, so an
    /// unparseable pair still gates the way the original equality check did.
    public nonisolated static func isBehind(_ local: String, _ live: String) -> Bool {
        let l = local.split(separator: ".").map { Int($0) }
        let r = live.split(separator: ".").map { Int($0) }
        guard !l.contains(nil), !r.contains(nil) else { return local != live }
        let a = l.compactMap { $0 }, b = r.compactMap { $0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    // MARK: - Declined updates (support case 2026-11-19)
    //
    // clientsettingscdn can report a MacPlayer build that Roblox itself
    // won't install yet (a staged or non-forced rollout). Opening Roblox
    // then changes nothing, and before this memo every Launch As tripped
    // the gate again: a dead end. Once Roblox has been opened and has
    // declined to move off `local`, that exact pair launches. A new
    // install or a new live version clears it by not matching.

    public static let declinedDefaultsKey = "RobloxVersionGate.declinedPair"

    public nonisolated static func declinedPair(defaults: UserDefaults = .standard) -> (local: String, live: String)? {
        guard let pair = defaults.stringArray(forKey: declinedDefaultsKey), pair.count == 2 else { return nil }
        return (pair[0], pair[1])
    }

    public nonisolated static func recordDeclined(local: String, live: String, defaults: UserDefaults = .standard) {
        defaults.set([local, live], forKey: declinedDefaultsKey)
    }

    /// `CFBundleShortVersionString` of the bundle at `appPath`, or nil if
    /// the bundle / plist / key is missing. Roblox's Mac player writes
    /// the full four-part build (e.g. `0.738.0.7381393`) here, which is
    /// the same string clientsettingscdn reports as `version`.
    public nonisolated static func localVersion(appPath: String) -> String? {
        let plistURL = URL(fileURLWithPath: appPath, isDirectory: true)
            .appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String,
              !version.isEmpty
        else { return nil }
        return version
    }

    // MARK: - Live fetch (cached)

    /// Live MacPlayer version, from cache when fresh. nil on any failure.
    public func liveVersion() async -> String? {
        if let cachedLive, Date().timeIntervalSince(cachedLive.fetchedAt) < cacheTTL {
            return cachedLive.version
        }

        let session = Self.urlSessionForTesting ?? URLSession.shared
        var request = URLRequest(url: Self.liveVersionURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let parsed = try JSONDecoder().decode(LiveVersionResponse.self, from: data)
            guard !parsed.version.isEmpty else { return nil }
            cachedLive = (parsed.version, Date())
            return parsed.version
        } catch {
            NSLog("[RORORO] RobloxVersionGate: live version fetch failed: %@", error.localizedDescription)
            return nil
        }
    }

    // MARK: - Preflight

    /// Compare the local bundle with the live version. Run before the
    /// per-instance copy; `.stale` means don't copy.
    public func preflight() async -> Verdict {
        let local = Self.localVersion(appPath: appPath)
        guard local != nil else { return .unknown }
        let live = await liveVersion()
        return Self.verdict(local: local, live: live, declined: Self.declinedPair(defaults: defaults))
    }
}
