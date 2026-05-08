// RobloxBundleResolverTests.swift
// Pure-FileManager validation; the Spotlight branch is integration-tested
// separately when a real Roblox.app is present and is skipped here so CI
// doesn't depend on Spotlight indexing or a particular Roblox install.

import XCTest
@testable import RORORO

final class RobloxBundleResolverTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rororo-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    // MARK: - validate

    func testValidate_AcceptsBundleWithRobloxBundleIdentifier() throws {
        let bundle = try makeFakeBundle(at: "FakeRoblox.app", bundleId: "com.roblox.RobloxPlayer")

        XCTAssertTrue(RobloxBundleResolver.validate(bundleAt: bundle))
    }

    func testValidate_AcceptsBundleWithCustomRobloxIdentifierFlavor() throws {
        // AppleBlox's resolver only checks the `com.roblox` prefix — Studio
        // and channel-switched builds use other flavors. We mirror the loose check.
        let bundle = try makeFakeBundle(at: "FakeStudio.app", bundleId: "com.roblox.RobloxStudio")

        XCTAssertTrue(RobloxBundleResolver.validate(bundleAt: bundle))
    }

    func testValidate_RejectsNonRobloxBundle() throws {
        let bundle = try makeFakeBundle(at: "Other.app", bundleId: "com.example.Other")

        XCTAssertFalse(RobloxBundleResolver.validate(bundleAt: bundle))
    }

    func testValidate_RejectsMissingPath() {
        let url = tempDir.appendingPathComponent("DoesNotExist.app", isDirectory: true)

        XCTAssertFalse(RobloxBundleResolver.validate(bundleAt: url))
    }

    func testValidate_RejectsBundleWithMissingInfoPlist() throws {
        let bundle = tempDir.appendingPathComponent("NoPlist.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        XCTAssertFalse(RobloxBundleResolver.validate(bundleAt: bundle))
    }

    // MARK: - fallback candidates

    func testFallbackCandidates_OrderedSlashApplicationsFirstThenHomeApplications() {
        let candidates = RobloxBundleResolver.fallbackCandidates()

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].path, "/Applications/Roblox.app")
        XCTAssertTrue(candidates[1].path.hasSuffix("/Applications/Roblox.app"))
        XCTAssertNotEqual(candidates[0].path, candidates[1].path)
    }

    // MARK: - Fixtures

    private func makeFakeBundle(at name: String, bundleId: String) throws -> URL {
        let bundle = tempDir.appendingPathComponent(name, isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        let plist: [String: Any] = ["CFBundleIdentifier": bundleId]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return bundle
    }
}
