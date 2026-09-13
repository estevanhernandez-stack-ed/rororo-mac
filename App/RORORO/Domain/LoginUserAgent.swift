// LoginUserAgent.swift
// Domain — the User-Agent suffix for the embedded Roblox login page.
//
// WKWebView's default UA on macOS ends at "(KHTML, like Gecko)". Real
// Safari continues with "Version/<safari> Safari/605.1.15". Roblox's
// captcha vendor reads the truncated shape as an embedded browser and
// keeps re-challenging — observed 2026-09-13: a main account could not
// get past the captcha in the Add Account sheet at all.
//
// Appending the two tokens via WKWebViewConfiguration.applicationName-
// ForUserAgent makes the UA identical in format to Safari's. This is not
// impersonating another browser: the engine IS Safari's WebKit, and the
// Version token is read from the Safari actually installed on the
// machine. The API client (RobloxApi) keeps its honest RORORO-Mac/<v>
// UA; docs/PRIVACY.md records both.

import Foundation

public enum LoginUserAgent {

    /// WebKit's build token. Stable across many macOS releases; Safari's
    /// own UA carries the same value in both AppleWebKit/… and Safari/….
    public static let webKitBuild = "605.1.15"

    /// Used when Safari's version can't be read (Safari missing, plist
    /// unreadable, garbage value). A plausible current-era version keeps
    /// the token shape right; the exact number isn't load-bearing.
    public static let fallbackSafariVersion = "18.0"

    /// `Version/<safari> Safari/<webkit>` — the suffix real Safari sends.
    public static func applicationName(safariVersion: String?) -> String {
        let version = safariVersion.flatMap(Self.validated) ?? fallbackSafariVersion
        return "Version/\(version) Safari/\(webKitBuild)"
    }

    /// Read CFBundleShortVersionString from the installed Safari.app.
    public static func installedSafariVersion(appPath: String = "/Applications/Safari.app") -> String? {
        let plistURL = URL(fileURLWithPath: appPath, isDirectory: true)
            .appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String
        else { return nil }
        return validated(version)
    }

    /// Production entry point: the suffix for this machine.
    public static func defaultApplicationName() -> String {
        applicationName(safariVersion: installedSafariVersion())
    }

    /// Dotted digits only (e.g. "18.6", "17.4.1"); anything else → nil.
    private static func validated(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isNumber || $0 == "." }),
              !trimmed.hasPrefix("."), !trimmed.hasSuffix("."),
              !trimmed.contains("..")
        else { return nil }
        return trimmed
    }
}
