// InboundLaunchURLParserTests.swift
// Unit tests for InboundLaunchURLParser.placeId(from:).

import XCTest
@testable import RORORO

final class InboundLaunchURLParserTests: XCTestCase {

    /// A realistic deep-link URI, shape-matching what
    /// RobloxLauncher.buildLaunchURI emits.
    func testPlaceId_RealisticDeepLinkURI_ParsesPlaceId() {
        let placeLauncher = "https://assetgame.roblox.com/game/PlaceLauncher.ashx?request=RequestGame&browserTrackerId=12345&placeId=987654321&isPlayTogetherGame=false"
        let escaped = placeLauncher.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let uri = "roblox-player:1+launchmode:play+gameinfo:abc123+launchtime:1700000000000+placelauncherurl:\(escaped)+browsertrackerid:12345+robloxLocale:en_us+gameLocale:en_us"
        let url = URL(string: uri)!

        XCTAssertEqual(InboundLaunchURLParser.placeId(from: url), 987654321)
    }

    func testPlaceId_TrailingPlacelauncherurl_StillParses() {
        // Some browsers strip trailing segments; placelauncherurl ending
        // the URI with no `+` after must still parse.
        let placeLauncher = "https://assetgame.roblox.com/game/PlaceLauncher.ashx?request=RequestGame&placeId=42"
        let escaped = placeLauncher.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let uri = "roblox-player:1+launchmode:play+placelauncherurl:\(escaped)"
        let url = URL(string: uri)!

        XCTAssertEqual(InboundLaunchURLParser.placeId(from: url), 42)
    }

    func testPlaceId_MissingPlacelauncherurl_ReturnsNil() {
        let url = URL(string: "roblox-player:1+launchmode:play+gameinfo:abc")!
        XCTAssertNil(InboundLaunchURLParser.placeId(from: url))
    }

    func testPlaceId_PlacelauncherurlButNoPlaceIdParam_ReturnsNil() {
        let placeLauncher = "https://assetgame.roblox.com/game/PlaceLauncher.ashx?request=RequestGame"
        let escaped = placeLauncher.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let uri = "roblox-player:1+launchmode:play+placelauncherurl:\(escaped)+browsertrackerid:12345"
        let url = URL(string: uri)!

        XCTAssertNil(InboundLaunchURLParser.placeId(from: url))
    }

    func testPlaceId_ZeroPlaceId_ReturnsNil() {
        // Defensive: placeId must be positive. Zero (or negative) is
        // not a valid Roblox place id and indicates a malformed URI.
        let placeLauncher = "https://assetgame.roblox.com/game/PlaceLauncher.ashx?request=RequestGame&placeId=0"
        let escaped = placeLauncher.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let uri = "roblox-player:1+launchmode:play+placelauncherurl:\(escaped)"
        let url = URL(string: uri)!

        XCTAssertNil(InboundLaunchURLParser.placeId(from: url))
    }

    func testPlaceId_NonNumericPlaceId_ReturnsNil() {
        let placeLauncher = "https://assetgame.roblox.com/game/PlaceLauncher.ashx?request=RequestGame&placeId=not-a-number"
        let escaped = placeLauncher.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let uri = "roblox-player:1+launchmode:play+placelauncherurl:\(escaped)"
        let url = URL(string: uri)!

        XCTAssertNil(InboundLaunchURLParser.placeId(from: url))
    }
}
