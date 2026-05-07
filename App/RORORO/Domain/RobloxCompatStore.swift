// RobloxCompatStore.swift
// Domain — fetches + caches the remote `roblox-compat.json` config.
//
// Lifecycle: MultiInstanceCoordinator.bootIfNeeded() kicks off a refresh
// at app launch. Cached config persists to
// `~/Library/Application Support/RORORO/roblox-compat.cache.json` so
// offline launches still get the most recent successfully-fetched value.
// In-memory copy is good for the app's lifetime; refresh again on
// `manualRefresh()` from the UI.
//
// SemaphoreBreaker is intentionally NOT auto-wired to this store — it
// stays a pure utility. Callers (MultiInstanceCoordinator) read the
// current effective semaphore name from this store and pass it to
// `breakRobloxSingleton(name:)`.

import Foundation
import Observation

@MainActor
@Observable
public final class RobloxCompatStore {

    public static let shared = RobloxCompatStore()

    public static let feedURL = URL(
        string: "https://estevanhernandez-stack-ed.github.io/rororo-mac/roblox-compat.json"
    )!

    public private(set) var config: RobloxCompatConfig?
    public private(set) var lastFetchedAt: Date?
    public private(set) var lastFetchError: String?

    /// Test seam mirroring `RobloxApi.urlSessionForTesting`.
    nonisolated(unsafe) public static var urlSessionForTesting: URLSession?

    /// File-based override for tests.
    private let cacheURL: URL

    private init() {
        self.cacheURL = Self.defaultCacheURL()
        loadCache()
    }

    /// Test-only initializer.
    internal init(cacheURL: URL) {
        self.cacheURL = cacheURL
        loadCache()
    }

    /// The current effective semaphore name. Falls back to
    /// `SemaphoreBreaker.robloxSingletonSemaphoreName` if no config has
    /// loaded — covers offline first-launch and before-fetch states.
    public func currentSemaphoreName() -> String {
        config?.semaphoreName ?? SemaphoreBreaker.robloxSingletonSemaphoreName
    }

    /// Indicates whether the in-memory config came from the network this
    /// session, an offline cache file, or neither. Used by DiagnosticsView.
    public func freshness() -> String {
        if let fetchedAt = lastFetchedAt {
            return "Fetched \(fetchedAt.formatted(.relative(presentation: .named)))"
        }
        if config != nil {
            return "Loaded from cache (no successful fetch this session)"
        }
        return "Using hardcoded fallback"
    }

    /// Hit the feed URL. Updates in-memory config + cache file on
    /// success; preserves prior values + records an error string on
    /// failure. Safe to call on every app boot.
    public func refresh() async {
        let session = Self.urlSessionForTesting ?? URLSession.shared
        var request = URLRequest(url: Self.feedURL)
        request.setValue("RORORO-Mac/0.2.0", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lastFetchError = "Non-HTTP response from compat feed."
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                lastFetchError = "Compat feed returned HTTP \(http.statusCode)."
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let parsed = try decoder.decode(RobloxCompatConfig.self, from: data)
            // Reject unknown schema versions instead of silently accepting.
            // If the shape changes, ship an app update first that knows
            // version N+1; until then, ignore the new format.
            guard parsed.version == 1 else {
                lastFetchError = "Compat feed reports schemaVersion \(parsed.version) — this app supports 1. Update RORORO."
                return
            }
            self.config = parsed
            self.lastFetchedAt = Date()
            self.lastFetchError = nil
            saveCache(data: data)
        } catch {
            lastFetchError = error.localizedDescription
        }
    }

    // MARK: - Cache

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let parsed = try? decoder.decode(RobloxCompatConfig.self, from: data),
           parsed.version == 1 {
            self.config = parsed
        }
    }

    private func saveCache(data: Data) {
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func defaultCacheURL() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("RORORO", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("roblox-compat.cache.json", isDirectory: false)
    }
}
