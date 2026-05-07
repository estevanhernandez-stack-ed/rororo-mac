// LaunchTargetTests.swift
// Ported table-driven from RORORO Windows (src/ROROROblox.Tests/LaunchTargetTests.cs).
// BuildPlaceLauncherUrl tests live in RobloxLauncherTests (Phase 2).

import XCTest
@testable import RORORO

final class LaunchTargetTests: XCTestCase {

    // MARK: - fromUrl parsing

    func testFromUrl_PublicGameUrl_ReturnsPlace() {
        let target = LaunchTarget.fromUrl("https://www.roblox.com/games/920587237/Adopt-Me")
        XCTAssertEqual(target, .place(placeId: 920587237))
    }

    func testFromUrl_PublicGameUrlWithoutSlug_ReturnsPlace() {
        let target = LaunchTarget.fromUrl("https://www.roblox.com/games/920587237")
        XCTAssertEqual(target, .place(placeId: 920587237))
    }

    func testFromUrl_BareNumeric_ReturnsPlace() {
        let target = LaunchTarget.fromUrl("920587237")
        XCTAssertEqual(target, .place(placeId: 920587237))
    }

    func testFromUrl_PrivateServerShareUrl_ReturnsLinkCodeKind() {
        let target = LaunchTarget.fromUrl(
            "https://www.roblox.com/games/920587237/Adopt-Me?privateServerLinkCode=ABC-123_xyz"
        )
        XCTAssertEqual(
            target,
            .privateServer(placeId: 920587237, code: "ABC-123_xyz", kind: .linkCode)
        )
    }

    func testFromUrl_LinkCodeAlias_AlsoTaggedAsLinkCode() {
        let target = LaunchTarget.fromUrl("https://www.roblox.com/games/100/Foo?linkCode=KKK")
        XCTAssertEqual(
            target,
            .privateServer(placeId: 100, code: "KKK", kind: .linkCode)
        )
    }

    func testFromUrl_PlaceLauncherWithAccessCode_TaggedAsAccessCode() {
        let target = LaunchTarget.fromUrl(
            "https://assetgame.roblox.com/game/PlaceLauncher.ashx?request=RequestPrivateGame&placeId=42&accessCode=secret"
        )
        XCTAssertEqual(
            target,
            .privateServer(placeId: 42, code: "secret", kind: .accessCode)
        )
    }

    func testFromUrl_LinkCodeBeatsAccessCode_WhenBothPresent() {
        // Defensive: a URL containing both params (rare but possible from
        // messy paste) prefers linkCode since that's what the share-link
        // path needs and is the stricter server-side-resolved path.
        let target = LaunchTarget.fromUrl(
            "https://www.roblox.com/games/42/Foo?privateServerLinkCode=LINK&accessCode=ACCESS"
        )
        XCTAssertEqual(
            target,
            .privateServer(placeId: 42, code: "LINK", kind: .linkCode)
        )
    }

    func testFromUrl_PlaceLauncherWithoutAccessCode_ReturnsPlace() {
        let target = LaunchTarget.fromUrl(
            "https://assetgame.roblox.com/game/PlaceLauncher.ashx?request=RequestGame&placeId=42"
        )
        XCTAssertEqual(target, .place(placeId: 42))
    }

    func testFromUrl_RobloxComShareUrl_ReturnsNil_RequiresAsyncResolution() {
        // The /share?code=X token URL needs an authenticated API call to
        // resolve to a real (placeId, linkCode) pair. Sync fromUrl returns
        // nil; callers route to the async resolver in Phase 2's RobloxApi.
        XCTAssertNil(LaunchTarget.fromUrl("https://www.roblox.com/share?code=ABC&type=Server"))
    }

    func testFromUrl_UnparseableInput_ReturnsNil() {
        let cases: [String?] = [
            nil,
            "",
            "   ",
            "not a url",
            "https://example.com/anything",
        ]
        for input in cases {
            XCTAssertNil(LaunchTarget.fromUrl(input), "expected nil for: \(input ?? "nil")")
        }
    }

    // MARK: - Friend-follow profile URLs

    func testFromUrl_ProfileURL_ReturnsFollowFriend() {
        XCTAssertEqual(
            LaunchTarget.fromUrl("https://www.roblox.com/users/12345/profile"),
            .followFriend(userId: 12345)
        )
    }

    func testFromUrl_ProfileURLWithoutSuffix_ReturnsFollowFriend() {
        XCTAssertEqual(
            LaunchTarget.fromUrl("https://www.roblox.com/users/98765"),
            .followFriend(userId: 98765)
        )
    }

    func testFromUrl_ZeroPlaceId_ReturnsNil() {
        XCTAssertNil(LaunchTarget.fromUrl("0"))
        XCTAssertNil(LaunchTarget.fromUrl("https://www.roblox.com/games/0"))
    }

    // MARK: - tryParseShareLink (the newer roblox.com/share?code=X&type=Y form)

    func testTryParseShareLink_ServerType_ExtractsCodeAndType() {
        let parsed = LaunchTarget.tryParseShareLink(
            "https://www.roblox.com/share?code=a5ad1dae7cb0bd47bd7f665614d5a3e6&type=Server"
        )
        XCTAssertEqual(
            parsed,
            LaunchTarget.ShareLinkParse(code: "a5ad1dae7cb0bd47bd7f665614d5a3e6", linkType: "Server")
        )
    }

    func testTryParseShareLink_TypeReversedQueryOrder_StillExtracted() {
        let parsed = LaunchTarget.tryParseShareLink(
            "https://www.roblox.com/share?type=Server&code=ABC"
        )
        XCTAssertEqual(parsed, LaunchTarget.ShareLinkParse(code: "ABC", linkType: "Server"))
    }

    func testTryParseShareLink_MissingType_DefaultsToServer() {
        let parsed = LaunchTarget.tryParseShareLink("https://www.roblox.com/share?code=ABC")
        XCTAssertEqual(parsed, LaunchTarget.ShareLinkParse(code: "ABC", linkType: "Server"))
    }

    func testTryParseShareLink_NotAShareUrl_ReturnsNil() {
        XCTAssertNil(LaunchTarget.tryParseShareLink(
            "https://www.roblox.com/games/12345/Foo?privateServerLinkCode=X"
        ))
        XCTAssertNil(LaunchTarget.tryParseShareLink(
            "https://example.com/share?code=X&type=Server"
        ))
        XCTAssertNil(LaunchTarget.tryParseShareLink(""))
        XCTAssertNil(LaunchTarget.tryParseShareLink(nil))
    }

    func testTryParseShareLink_MissingCode_ReturnsNil() {
        XCTAssertNil(LaunchTarget.tryParseShareLink("https://www.roblox.com/share?type=Server"))
    }
}
