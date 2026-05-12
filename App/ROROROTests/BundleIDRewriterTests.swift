import XCTest
@testable import RORORO

final class BundleIDRewriterTests: XCTestCase {

    private var tempRoot: URL!
    private var entitlementsURL: URL!

    override func setUp() {
        super.setUp()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rororo-rewriter-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        entitlementsURL = tempRoot.appendingPathComponent("test-relax-libval.plist")
        let entitlementsXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.security.cs.disable-library-validation</key>
            <true/>
        </dict>
        </plist>
        """
        try? entitlementsXML.write(to: entitlementsURL, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testRewritesBundleIDAndFlipsMultiInstanceFlag() throws {
        let fixtureApp = try makeFixtureApp(
            bundleID: "com.example.original",
            multipleInstancesProhibited: true
        )

        let newID = "com.626labs.RORORO.instance.test-\(UUID().uuidString.lowercased())"
        try BundleIDRewriter.rewrite(
            at: fixtureApp,
            newBundleID: newID,
            signingIdentity: "-",
            entitlementsPath: entitlementsURL.path
        )

        let plistURL = fixtureApp.appendingPathComponent("Contents/Info.plist")
        let plist = try plistDict(at: plistURL)
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, newID)
        XCTAssertEqual(plist["LSMultipleInstancesProhibited"] as? Bool, false)
    }

    func testReSignedBundleReportsNewIdentifierToCodesign() throws {
        let fixtureApp = try makeFixtureApp(
            bundleID: "com.example.fixture",
            multipleInstancesProhibited: true
        )

        let newID = "com.626labs.RORORO.instance.test-\(UUID().uuidString.lowercased())"
        try BundleIDRewriter.rewrite(
            at: fixtureApp,
            newBundleID: newID,
            signingIdentity: "-",
            entitlementsPath: entitlementsURL.path
        )

        let output = try runCodesign(["-dvv", fixtureApp.path])
        XCTAssertTrue(
            output.contains("Identifier=\(newID)"),
            "codesign -dvv output should include new identifier '\(newID)', got:\n\(output)"
        )
    }

    func testMissingEntitlementsThrowsBeforeTouchingPlist() throws {
        let fixtureApp = try makeFixtureApp(
            bundleID: "com.example.untouched",
            multipleInstancesProhibited: true
        )
        let originalPlist = try plistDict(at: fixtureApp.appendingPathComponent("Contents/Info.plist"))

        XCTAssertThrowsError(
            try BundleIDRewriter.rewrite(
                at: fixtureApp,
                newBundleID: "com.626labs.RORORO.instance.should-not-apply",
                signingIdentity: "-",
                entitlementsPath: "/tmp/nonexistent-entitlements-\(UUID().uuidString).plist"
            )
        ) { error in
            guard case BundleIDRewriter.RewriteError.entitlementsMissing = error else {
                return XCTFail("expected entitlementsMissing, got \(error)")
            }
        }

        let plistAfter = try plistDict(at: fixtureApp.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(plistAfter["CFBundleIdentifier"] as? String,
                       originalPlist["CFBundleIdentifier"] as? String,
                       "pre-flight failure must not mutate Info.plist")
    }

    // MARK: helpers

    private func makeFixtureApp(bundleID: String, multipleInstancesProhibited: Bool) throws -> URL {
        let appURL = tempRoot.appendingPathComponent("Fixture-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        let exec = appURL.appendingPathComponent("Contents/MacOS/Fixture")
        try "#!/bin/sh\nexit 0\n".write(to: exec, atomically: true, encoding: .utf8)
        var attrs = try FileManager.default.attributesOfItem(atPath: exec.path)
        attrs[.posixPermissions] = NSNumber(value: 0o755)
        try FileManager.default.setAttributes(attrs, ofItemAtPath: exec.path)

        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "Fixture",
            "CFBundleName": "Fixture",
            "LSMultipleInstancesProhibited": multipleInstancesProhibited
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: appURL.appendingPathComponent("Contents/Info.plist"))

        _ = try runCodesign(["--force", "--sign", "-", appURL.path])
        return appURL
    }

    private func plistDict(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        var fmt: PropertyListSerialization.PropertyListFormat = .xml
        let obj = try PropertyListSerialization.propertyList(from: data, format: &fmt)
        return (obj as? [String: Any]) ?? [:]
    }

    @discardableResult
    private func runCodesign(_ args: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        try task.run()
        task.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out + err
    }
}
