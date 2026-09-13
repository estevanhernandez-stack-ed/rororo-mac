// LoginUserAgentTests.swift
// The login WKWebView's default User-Agent lacks the trailing
// "Version/x Safari/605.1.15" tokens a real Safari sends, and Roblox's
// captcha vendor treats that shape as an embedded browser and keeps
// re-challenging (observed 2026-09-13 on a main account). We append the
// tokens via WKWebViewConfiguration.applicationNameForUserAgent using
// the Safari version actually installed on the machine — same engine,
// same format, nothing invented.

import XCTest
@testable import RORORO

final class LoginUserAgentTests: XCTestCase {

    func testApplicationName_UsesInstalledSafariVersion() {
        XCTAssertEqual(
            LoginUserAgent.applicationName(safariVersion: "18.6"),
            "Version/18.6 Safari/605.1.15"
        )
    }

    func testApplicationName_FallsBackWhenSafariVersionUnknown() {
        let name = LoginUserAgent.applicationName(safariVersion: nil)
        XCTAssertTrue(name.hasPrefix("Version/"), "still needs a Version token")
        XCTAssertTrue(name.hasSuffix("Safari/605.1.15"))
    }

    func testApplicationName_RejectsGarbageVersion() {
        // A version string that isn't dotted digits falls back rather
        // than shipping something odd in every login request.
        let name = LoginUserAgent.applicationName(safariVersion: "not a version")
        XCTAssertEqual(name, LoginUserAgent.applicationName(safariVersion: nil))
    }

    func testInstalledSafariVersion_ReadsPlistWhenPresent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rororo-safari-\(UUID().uuidString)/Safari.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": "18.6"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent("Info.plist"))
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }

        XCTAssertEqual(
            LoginUserAgent.installedSafariVersion(appPath: dir.deletingLastPathComponent().path),
            "18.6"
        )
        XCTAssertNil(LoginUserAgent.installedSafariVersion(appPath: "/nonexistent/Safari.app"))
    }
}
