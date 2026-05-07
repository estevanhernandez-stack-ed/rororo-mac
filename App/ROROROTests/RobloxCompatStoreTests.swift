// RobloxCompatStoreTests.swift
// JSON parsing + cache persistence + version-rejection.

import XCTest
@testable import RORORO

@MainActor
final class RobloxCompatStoreTests: XCTestCase {

    private var tempCacheURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempCacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rororo-compat-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("roblox-compat.cache.json", isDirectory: false)
    }

    override func tearDown() async throws {
        if let dir = tempCacheURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    // MARK: - Wire shape

    func testRobloxCompatConfig_DecodesV1Wire() throws {
        let json = """
        {
          "version": 1,
          "semaphoreName": "/RobloxPlayerUniq",
          "knownGoodRobloxVersion": "0.700.0.7000000",
          "minimumAppVersion": "0.1.0",
          "updatedAt": "2026-05-07T22:00:00Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let parsed = try decoder.decode(RobloxCompatConfig.self, from: json)

        XCTAssertEqual(parsed.version, 1)
        XCTAssertEqual(parsed.semaphoreName, "/RobloxPlayerUniq")
        XCTAssertEqual(parsed.knownGoodRobloxVersion, "0.700.0.7000000")
        XCTAssertEqual(parsed.minimumAppVersion, "0.1.0")
    }

    // MARK: - Fallback behavior

    func testCurrentSemaphoreName_UsesFallbackWhenNoCacheLoaded() {
        let store = RobloxCompatStore(cacheURL: tempCacheURL)
        XCTAssertEqual(store.currentSemaphoreName(), SemaphoreBreaker.robloxSingletonSemaphoreName)
    }

    func testCurrentSemaphoreName_UsesCachedValueWhenAvailable() throws {
        // Pre-populate the cache with a non-default value to verify the
        // store reads from disk on init.
        let cached = """
        {
          "version": 1,
          "semaphoreName": "/RobloxPlayerUniqRenamed2027",
          "minimumAppVersion": "0.1.0",
          "updatedAt": "2026-05-07T22:00:00Z"
        }
        """.data(using: .utf8)!
        try FileManager.default.createDirectory(
            at: tempCacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try cached.write(to: tempCacheURL)

        let store = RobloxCompatStore(cacheURL: tempCacheURL)
        XCTAssertEqual(store.currentSemaphoreName(), "/RobloxPlayerUniqRenamed2027")
    }

    func testCurrentSemaphoreName_RejectsUnknownSchemaVersion() throws {
        // Schema-version mismatch: the store should NOT load it. Falls
        // back to the hardcoded default. Forces a version-N+1 to ship
        // an app update first, before the format change goes live.
        let cached = """
        {
          "version": 99,
          "semaphoreName": "/SomeFutureFormat",
          "minimumAppVersion": "0.1.0",
          "updatedAt": "2026-05-07T22:00:00Z"
        }
        """.data(using: .utf8)!
        try FileManager.default.createDirectory(
            at: tempCacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try cached.write(to: tempCacheURL)

        let store = RobloxCompatStore(cacheURL: tempCacheURL)
        XCTAssertEqual(
            store.currentSemaphoreName(),
            SemaphoreBreaker.robloxSingletonSemaphoreName,
            "version-99 cache should be ignored; fall back to hardcoded default"
        )
    }
}
