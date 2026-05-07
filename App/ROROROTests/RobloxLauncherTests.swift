// RobloxLauncherTests.swift
// Snapshot + per-variant coverage of the static URI builders. Byte-identical
// outputs with RORORO Windows's RobloxLauncher.cs (snapshot tests below).
// Drift in either port without updating the other risks breaking
// account-roaming compatibility later.

import XCTest
@testable import RORORO

final class RobloxLauncherTests: XCTestCase {

    // MARK: - buildLaunchURI (snapshot)

    func testBuildLaunchURI_HasExpectedShape_WithFixedInputs() throws {
        let uri = try RobloxLauncher.buildLaunchURI(
            ticket: "TICKET-AAA",
            launchTime: 1714780000000,
            browserTrackerId: "1234567890123",
            placeUrl: "https://example.com/place?placeId=42"
        )

        let expected =
            "roblox-player:1+launchmode:play"
            + "+gameinfo:TICKET-AAA"
            + "+launchtime:1714780000000"
            + "+placelauncherurl:https%3A%2F%2Fexample.com%2Fplace%3FplaceId%3D42"
            + "+browsertrackerid:1234567890123"
            + "+robloxLocale:en_us+gameLocale:en_us"

        XCTAssertEqual(uri, expected)
    }

    func testBuildLaunchURI_EncodesPlaceUrl() throws {
        let uri = try RobloxLauncher.buildLaunchURI(
            ticket: "T",
            launchTime: 0,
            browserTrackerId: "1",
            placeUrl: "https://x.example/path with spaces&query=1"
        )
        XCTAssertTrue(uri.contains("+placelauncherurl:https%3A%2F%2Fx.example%2Fpath%20with%20spaces%26query%3D1"))
    }

    func testBuildLaunchURI_RejectsEmptyTicket() {
        XCTAssertThrowsError(try RobloxLauncher.buildLaunchURI(
            ticket: "", launchTime: 0, browserTrackerId: "1", placeUrl: "https://x"
        )) { error in
            XCTAssertEqual(error as? RobloxLauncher.LauncherError, .emptyTicket)
        }
    }

    func testBuildLaunchURI_RejectsEmptyPlaceUrl() {
        XCTAssertThrowsError(try RobloxLauncher.buildLaunchURI(
            ticket: "T", launchTime: 0, browserTrackerId: "1", placeUrl: ""
        )) { error in
            XCTAssertEqual(error as? RobloxLauncher.LauncherError, .emptyPlaceURL)
        }
    }

    func testBuildLaunchURI_RejectsEmptyBrowserTrackerId() {
        XCTAssertThrowsError(try RobloxLauncher.buildLaunchURI(
            ticket: "T", launchTime: 0, browserTrackerId: "", placeUrl: "https://x"
        )) { error in
            XCTAssertEqual(error as? RobloxLauncher.LauncherError, .emptyBrowserTrackerId)
        }
    }

    // MARK: - buildPlaceLauncherUrl per variant

    func testBuildPlaceLauncherUrl_Place_ProducesRequestGameForm() throws {
        let url = try RobloxLauncher.buildPlaceLauncherUrl(
            target: .place(placeId: 12345),
            browserTrackerId: "BT-1"
        )

        XCTAssertTrue(url.contains("PlaceLauncher.ashx"))
        XCTAssertTrue(url.contains("request=RequestGame"))
        XCTAssertTrue(url.contains("browserTrackerId=BT-1"))
        XCTAssertTrue(url.contains("placeId=12345"))
        XCTAssertTrue(url.contains("isPlayTogetherGame=false"))
    }

    func testBuildPlaceLauncherUrl_PrivateServer_LinkCodeKind_EmitsOnlyLinkCodeSlot() throws {
        let url = try RobloxLauncher.buildPlaceLauncherUrl(
            target: .privateServer(placeId: 12345, code: "SHARE_TOKEN", kind: .linkCode),
            browserTrackerId: "BT-1"
        )

        XCTAssertTrue(url.contains("request=RequestPrivateGame"))
        XCTAssertTrue(url.contains("placeId=12345"))
        XCTAssertTrue(url.contains("linkCode=SHARE_TOKEN"))
        // Critical: don't ALSO emit accessCode= when the value is a link code.
        XCTAssertFalse(url.contains("accessCode="))
    }

    func testBuildPlaceLauncherUrl_PrivateServer_AccessCodeKind_EmitsOnlyAccessCodeSlot() throws {
        let url = try RobloxLauncher.buildPlaceLauncherUrl(
            target: .privateServer(placeId: 12345, code: "RAW_ACCESS", kind: .accessCode),
            browserTrackerId: "BT-1"
        )

        XCTAssertTrue(url.contains("request=RequestPrivateGame"))
        XCTAssertTrue(url.contains("placeId=12345"))
        XCTAssertTrue(url.contains("accessCode=RAW_ACCESS"))
        XCTAssertFalse(url.contains("linkCode="))
    }

    func testBuildPlaceLauncherUrl_PrivateServer_UrlEncodesCode() throws {
        let url = try RobloxLauncher.buildPlaceLauncherUrl(
            target: .privateServer(placeId: 12345, code: "code with spaces&special=chars", kind: .linkCode),
            browserTrackerId: "1"
        )
        // RFC 3986: spaces → %20, & → %26, = → %3D
        XCTAssertTrue(url.contains("code%20with%20spaces%26special%3Dchars"))
    }

    func testBuildPlaceLauncherUrl_FollowFriend_ProducesRequestFollowUserForm() throws {
        let url = try RobloxLauncher.buildPlaceLauncherUrl(
            target: .followFriend(userId: 98765),
            browserTrackerId: "BT-1"
        )

        XCTAssertTrue(url.contains("request=RequestFollowUser"))
        XCTAssertTrue(url.contains("userId=98765"))
        XCTAssertFalse(url.contains("placeId="))
    }

    func testBuildPlaceLauncherUrl_DefaultGame_Throws() {
        XCTAssertThrowsError(try RobloxLauncher.buildPlaceLauncherUrl(
            target: .defaultGame, browserTrackerId: "BT"
        )) { error in
            XCTAssertEqual(error as? RobloxLauncher.LauncherError, .unresolvedDefaultGame)
        }
    }

    func testBuildPlaceLauncherUrl_RejectsEmptyTrackerId() {
        XCTAssertThrowsError(try RobloxLauncher.buildPlaceLauncherUrl(
            target: .place(placeId: 1), browserTrackerId: ""
        )) { error in
            XCTAssertEqual(error as? RobloxLauncher.LauncherError, .emptyBrowserTrackerId)
        }
    }

    func testBuildPlaceLauncherUrl_RejectsZeroPlaceId() {
        XCTAssertThrowsError(try RobloxLauncher.buildPlaceLauncherUrl(
            target: .place(placeId: 0), browserTrackerId: "BT"
        )) { error in
            switch error {
            case RobloxLauncher.LauncherError.invalidTarget: break
            default: XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testBuildPlaceLauncherUrl_RejectsZeroFollowUserId() {
        XCTAssertThrowsError(try RobloxLauncher.buildPlaceLauncherUrl(
            target: .followFriend(userId: 0), browserTrackerId: "BT"
        )) { error in
            switch error {
            case RobloxLauncher.LauncherError.invalidTarget: break
            default: XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testBuildPlaceLauncherUrl_RejectsEmptyCode() {
        XCTAssertThrowsError(try RobloxLauncher.buildPlaceLauncherUrl(
            target: .privateServer(placeId: 1, code: "", kind: .linkCode),
            browserTrackerId: "BT"
        )) { error in
            switch error {
            case RobloxLauncher.LauncherError.invalidTarget: break
            default: XCTFail("Wrong error type: \(error)")
            }
        }
    }

    // MARK: - normalizeToPlaceLauncherUrl

    func testNormalizeToPlaceLauncherUrl_PublicGameUrl_RewritesToPlaceLauncherForm() {
        let result = RobloxLauncher.normalizeToPlaceLauncherUrl(
            "https://www.roblox.com/games/920587237/Adopt-Me",
            browserTrackerId: "12345"
        )
        XCTAssertTrue(result.contains("assetgame.roblox.com/game/PlaceLauncher.ashx"))
        XCTAssertTrue(result.contains("placeId=920587237"))
        XCTAssertTrue(result.contains("browserTrackerId=12345"))
        XCTAssertTrue(result.contains("request=RequestGame"))
    }

    func testNormalizeToPlaceLauncherUrl_PublicGameUrl_WithoutSlug_StillExtractsId() {
        let result = RobloxLauncher.normalizeToPlaceLauncherUrl(
            "https://www.roblox.com/games/920587237",
            browserTrackerId: "12345"
        )
        XCTAssertTrue(result.contains("placeId=920587237"))
    }

    func testNormalizeToPlaceLauncherUrl_AlreadyPlaceLauncherUrl_PassesThroughUnchanged() {
        let input = "https://assetgame.roblox.com/game/PlaceLauncher.ashx?request=RequestGame&browserTrackerId=99&placeId=12345&isPlayTogetherGame=false"
        let result = RobloxLauncher.normalizeToPlaceLauncherUrl(input, browserTrackerId: "12345")
        XCTAssertEqual(result, input)
    }

    func testNormalizeToPlaceLauncherUrl_BareNumericPlaceId_WrapsInPlaceLauncherForm() {
        let result = RobloxLauncher.normalizeToPlaceLauncherUrl("920587237", browserTrackerId: "12345")
        XCTAssertTrue(result.contains("placeId=920587237"))
        XCTAssertTrue(result.contains("PlaceLauncher.ashx"))
    }

    func testNormalizeToPlaceLauncherUrl_UnrecognizedInput_PassesThrough() {
        let input = "https://example.com/some/random/url"
        let result = RobloxLauncher.normalizeToPlaceLauncherUrl(input, browserTrackerId: "12345")
        XCTAssertEqual(result, input)
    }

    func testNormalizeToPlaceLauncherUrl_WorksWithoutWww() {
        let result = RobloxLauncher.normalizeToPlaceLauncherUrl(
            "https://roblox.com/games/920587237/Adopt-Me",
            browserTrackerId: "1"
        )
        XCTAssertTrue(result.contains("placeId=920587237"))
    }

    // MARK: - extractPlaceId

    func testExtractPlaceId_FromPlaceLauncherUrl() {
        XCTAssertEqual(
            RobloxLauncher.extractPlaceId(
                "https://assetgame.roblox.com/game/PlaceLauncher.ashx?request=RequestGame&placeId=42"
            ),
            42
        )
    }

    func testExtractPlaceId_FromGameUrl() {
        XCTAssertEqual(
            RobloxLauncher.extractPlaceId("https://www.roblox.com/games/920587237/Adopt-Me"),
            920587237
        )
    }

    func testExtractPlaceId_FromBareNumeric() {
        XCTAssertEqual(RobloxLauncher.extractPlaceId("920587237"), 920587237)
    }

    func testExtractPlaceId_FromEmpty_ReturnsNil() {
        XCTAssertNil(RobloxLauncher.extractPlaceId(""))
    }

    func testExtractPlaceId_FromUnparseable_ReturnsNil() {
        XCTAssertNil(RobloxLauncher.extractPlaceId("https://example.com/anything"))
    }
}
