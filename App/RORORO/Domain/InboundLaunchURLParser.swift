// InboundLaunchURLParser.swift
// Domain — best-effort parse of an inbound `roblox-player://...` deep-
// link URI (as fired by a browser Play-button click) into a value the
// rest of the app understands.
//
// The URI shape is the one this codebase emits via
// `RobloxLauncher.buildLaunchURI`:
//
//   roblox-player:1+launchmode:play+gameinfo:<ticket>+launchtime:<ts>+
//   placelauncherurl:<url-escaped-PlaceLauncher-url>+
//   browsertrackerid:<id>+robloxLocale:en_us+gameLocale:en_us
//
// The placeId is buried inside the URL-escaped `placelauncherurl:`
// segment as a `placeId=N` query param. To get from URL → LaunchTarget
// we have to: split on `+`, find the `placelauncherurl:` key, URL-
// decode its value, then parse the decoded URL's query string for
// `placeId`.
//
// Why not reuse `LaunchTarget.fromUrl(_:)`? That parser is for
// user-pasted `https://www.roblox.com/games/...` URLs and bare numeric
// IDs — fundamentally a different format from the deep-link URI shape.
// Mixing the two parsers would erode each one's invariants. v1 keeps
// them separate.
//
// Returns nil for unparseable URIs; callers fall back to
// `LaunchTarget.defaultGame` (resolved via the user's favorite or
// settings) so a malformed URL still produces a launch attempt rather
// than a silent drop.

import Foundation

public enum InboundLaunchURLParser {

    /// Extract the placeId from a `roblox-player://...` deep-link URI.
    /// Returns nil if the URI doesn't match the expected shape or the
    /// placeId isn't present / isn't positive.
    public static func placeId(from url: URL) -> Int64? {
        let raw = url.absoluteString

        // Find the placelauncherurl: segment. Case-insensitive match —
        // some browsers normalize case in deep-link URIs.
        guard let range = raw.range(of: "placelauncherurl:", options: .caseInsensitive) else {
            return nil
        }

        // Value runs from after the `:` to the next `+` (segment
        // separator in the deep-link grammar), or to the end of string
        // if this is the trailing segment.
        let after = raw[range.upperBound...]
        let encodedValue: Substring
        if let plusIndex = after.firstIndex(of: "+") {
            encodedValue = after[..<plusIndex]
        } else {
            encodedValue = after
        }

        guard let decoded = String(encodedValue).removingPercentEncoding,
              let components = URLComponents(string: decoded),
              let placeIdItem = components.queryItems?.first(where: {
                  $0.name.caseInsensitiveCompare("placeId") == .orderedSame
              }),
              let placeIdString = placeIdItem.value,
              let placeId = Int64(placeIdString),
              placeId > 0
        else {
            return nil
        }
        return placeId
    }
}
