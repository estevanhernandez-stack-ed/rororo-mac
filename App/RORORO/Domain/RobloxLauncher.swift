// RobloxLauncher.swift
// Domain — URI construction + launch orchestration.
//
// Static methods (Phase 2): pure URI builders, snapshot-tested byte-identical
// to RORORO Windows.
//
// `RobloxLauncher.shared.launch(account:target:)` (Phase 5): the async
// orchestrator that ties together cookie pull → auth ticket → URI build →
// MultiInstanceCoordinator handoff. Per-row Launch As buttons in the UI
// call this; multi-instance happens transparently via the coordinator's
// claimed `roblox-player://` URL handler.
//
// Cross-platform parity: byte-identical output with RORORO Windows's
// RobloxLauncher.cs (snapshot-tested below). Account export/import between
// Windows and Mac is out of scope for v0.1.0 but the URI shape stays
// compatible so we don't have to renegotiate later.
//
// References (Windows port):
//   src/ROROROblox.Core/RobloxLauncher.cs::BuildLaunchUri
//   src/ROROROblox.Core/RobloxLauncher.cs::BuildPlaceLauncherUrl
//   src/ROROROblox.Core/RobloxLauncher.cs::NormalizeToPlaceLauncherUrl

import Foundation

public final class RobloxLauncher {

    public static let shared = RobloxLauncher()
    private init() {}

    public static let placeLauncherEndpoint = "https://assetgame.roblox.com/game/PlaceLauncher.ashx"

    public enum LauncherError: Error, Equatable {
        case emptyTicket
        case emptyPlaceURL
        case emptyBrowserTrackerId
        case invalidTarget(reason: String)
        case unresolvedDefaultGame
        case cookieMissing(userId: String)
        case invalidLaunchURI
    }

    // MARK: - Orchestration (Phase 5)

    /// Run the full launch flow for a saved account against a target.
    ///   1. Pull cookie from Keychain via AccountStore.
    ///   2. Fetch one-shot auth ticket from Roblox.
    ///   3. Resolve `.defaultGame` against FavoriteGameStore if needed.
    ///   4. Build the PlaceLauncher.ashx URL + the full `roblox-player:` URI.
    ///   5. Hand to MultiInstanceCoordinator (which runs the copy / break / spawn recipe).
    ///   6. Update AccountStore.lastLaunchedAt.
    /// Throws on any failure. UI catches + surfaces via banner.
    public func launch(account: Account, target: LaunchTarget) async throws {
        // (1) Cookie pull on main; KeychainStore is sync but AccountStore
        // is @MainActor so we hop.
        let cookie = try await MainActor.run {
            try AccountStore.shared.cookie(for: account.userId)
        }
        guard let cookie, !cookie.isEmpty else {
            throw LauncherError.cookieMissing(userId: account.userId)
        }

        // (2) Auth ticket. Throws RobloxApi.APIError on failure — caller
        // can `catch as RobloxApi.APIError` to distinguish cookieExpired.
        let authTicket = try await RobloxApi.getAuthTicket(cookie: cookie)

        // (3) Resolve default game. Reads from FavoriteGameStore on main.
        let resolvedTarget = try await MainActor.run {
            try Self.resolveDefaultGame(target)
        }

        // (4) Build URIs.
        let browserTrackerId = String(Int64.random(in: 1_000_000_000_000...9_999_999_999_999))
        let placeUrl = try RobloxLauncher.buildPlaceLauncherUrl(
            target: resolvedTarget,
            browserTrackerId: browserTrackerId
        )
        let launchTime = Int64(Date().timeIntervalSince1970 * 1000)
        let uri = try RobloxLauncher.buildLaunchURI(
            ticket: authTicket.ticket,
            launchTime: launchTime,
            browserTrackerId: browserTrackerId,
            placeUrl: placeUrl
        )

        // (5) Hand to coordinator on main.
        guard let url = URL(string: uri) else {
            throw LauncherError.invalidLaunchURI
        }
        await MainActor.run {
            MultiInstanceCoordinator.shared.handleIncomingURL(url)
            AccountStore.shared.touchLastLaunched(userId: account.userId)
        }
    }

    @MainActor
    private static func resolveDefaultGame(_ target: LaunchTarget) throws -> LaunchTarget {
        if case .defaultGame = target {
            guard let defaultGame = FavoriteGameStore.shared.defaultGame() else {
                throw LauncherError.unresolvedDefaultGame
            }
            return .place(placeId: defaultGame.placeId)
        }
        return target
    }

    // MARK: - URI builders (Phase 2 — unchanged)

    /// Build the `placelauncherurl=` value Roblox expects for each launch
    /// target shape. Throws on invalid inputs (zero placeId, empty code,
    /// unresolved DefaultGame). Public for snapshot testing.
    public static func buildPlaceLauncherUrl(
        target: LaunchTarget,
        browserTrackerId: String
    ) throws -> String {
        guard !browserTrackerId.isEmpty else {
            throw LauncherError.emptyBrowserTrackerId
        }

        switch target {
        case .place(let placeId):
            guard placeId > 0 else {
                throw LauncherError.invalidTarget(reason: "placeId must be positive")
            }
            return placeLauncherEndpoint
                + "?request=RequestGame"
                + "&browserTrackerId=\(browserTrackerId)"
                + "&placeId=\(placeId)"
                + "&isPlayTogetherGame=false"

        case .privateServer(let placeId, let code, let kind):
            guard placeId > 0 else {
                throw LauncherError.invalidTarget(reason: "placeId must be positive")
            }
            guard !code.isEmpty else {
                throw LauncherError.invalidTarget(reason: "private-server code must not be empty")
            }
            // Emit ONLY the matching slot. The two codes are not interchangeable —
            // a linkCode in the accessCode slot returns permission-denied even
            // on owner servers.
            let slot = (kind == .linkCode) ? "linkCode" : "accessCode"
            let escapedCode = uriEscape(code)
            return placeLauncherEndpoint
                + "?request=RequestPrivateGame"
                + "&browserTrackerId=\(browserTrackerId)"
                + "&placeId=\(placeId)"
                + "&\(slot)=\(escapedCode)"

        case .followFriend(let userId):
            guard userId > 0 else {
                throw LauncherError.invalidTarget(reason: "userId must be positive")
            }
            // RequestFollowUser doesn't carry placeId — Roblox follows the
            // user wherever they are and does the permission check server-side.
            return placeLauncherEndpoint
                + "?request=RequestFollowUser"
                + "&browserTrackerId=\(browserTrackerId)"
                + "&userId=\(userId)"

        case .defaultGame:
            // DefaultGame must be resolved (via favorites or settings)
            // before reaching here. The resolver lives at Phase 5 alongside
            // the per-account launch button.
            throw LauncherError.unresolvedDefaultGame
        }
    }

    /// Pure URI construction — public for snapshot testing. Shape per the
    /// Windows port's spec §5.6 (placelauncherurl is required, not optional).
    public static func buildLaunchURI(
        ticket: String,
        launchTime: Int64,
        browserTrackerId: String,
        placeUrl: String
    ) throws -> String {
        guard !ticket.isEmpty else { throw LauncherError.emptyTicket }
        guard !placeUrl.isEmpty else { throw LauncherError.emptyPlaceURL }
        guard !browserTrackerId.isEmpty else { throw LauncherError.emptyBrowserTrackerId }

        var uri = "roblox-player:1"
        uri += "+launchmode:play"
        uri += "+gameinfo:\(ticket)"
        uri += "+launchtime:\(launchTime)"
        uri += "+placelauncherurl:\(uriEscape(placeUrl))"
        uri += "+browsertrackerid:\(browserTrackerId)"
        uri += "+robloxLocale:en_us+gameLocale:en_us"
        return uri
    }

    /// Convert a user-friendly Roblox game URL into the PlaceLauncher.ashx
    /// form RobloxPlayerLauncher expects. Accepts:
    ///   - `https://www.roblox.com/games/{id}/{slug}`  → normalized
    ///   - `https://www.roblox.com/games/{id}`          → normalized
    ///   - existing PlaceLauncher URL                   → passed through unchanged
    ///   - bare numeric place id                        → wrapped in PlaceLauncher form
    ///   - anything else                                → passed through (caller may have a non-standard form)
    public static func normalizeToPlaceLauncherUrl(_ input: String, browserTrackerId: String) -> String {
        guard !input.isEmpty else { return input }

        if input.range(of: "PlaceLauncher.ashx", options: .caseInsensitive) != nil {
            return input
        }

        if let placeId = firstCapture(in: input, pattern: #"roblox\.com/games/(\d+)"#) {
            return placeLauncherEndpoint
                + "?request=RequestGame"
                + "&browserTrackerId=\(browserTrackerId)"
                + "&placeId=\(placeId)"
                + "&isPlayTogetherGame=false"
        }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bareNumeric = firstCapture(in: trimmed, pattern: #"^(\d+)$"#) {
            return placeLauncherEndpoint
                + "?request=RequestGame"
                + "&browserTrackerId=\(browserTrackerId)"
                + "&placeId=\(bareNumeric)"
                + "&isPlayTogetherGame=false"
        }

        return input
    }

    /// Best-effort numeric place-id extractor for any of the input shapes
    /// `normalizeToPlaceLauncherUrl` accepts. Returns nil when no place id
    /// can be located. Used by Games dialog paste handling.
    public static func extractPlaceId(_ input: String) -> Int64? {
        guard !input.isEmpty else { return nil }

        if let captured = firstCapture(in: input, pattern: #"placeId=(\d+)"#),
           let value = Int64(captured) {
            return value
        }
        if let captured = firstCapture(in: input, pattern: #"roblox\.com/games/(\d+)"#),
           let value = Int64(captured) {
            return value
        }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Int64(trimmed), value > 0 {
            return value
        }
        return nil
    }
}

// MARK: - Internals

/// RFC 3986 percent-encoding. Matches .NET's `Uri.EscapeDataString`:
/// only unreserved chars (A-Za-z0-9 - _ . ~) pass through; everything else
/// is percent-encoded. Snapshot tests depend on byte-identical output.
private let rfc3986Unreserved: CharacterSet = {
    var s = CharacterSet()
    s.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    s.insert(charactersIn: "abcdefghijklmnopqrstuvwxyz")
    s.insert(charactersIn: "0123456789")
    s.insert(charactersIn: "-._~")
    return s
}()

private func uriEscape(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: rfc3986Unreserved) ?? s
}

private func firstCapture(in input: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return nil
    }
    let range = NSRange(input.startIndex..<input.endIndex, in: input)
    guard let match = regex.firstMatch(in: input, range: range),
          match.numberOfRanges > 1,
          let captureRange = Range(match.range(at: 1), in: input) else {
        return nil
    }
    return String(input[captureRange])
}
