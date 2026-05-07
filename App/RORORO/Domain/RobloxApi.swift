// RobloxApi.swift
// Domain — minimal HTTP client for Roblox endpoints needed by the launcher.
//
// Phase 2 scope: `getAuthTicket(cookie:)` — the load-bearing call that
// turns a `.ROBLOSECURITY` cookie into a one-shot RBX-Authentication-Ticket
// the engine pastes into the `roblox-player:` URI.
// Phase 4 adds: `getUserProfile(cookie:)` for /users/authenticated (drives
// the AccountStore add path after WKWebView captures a cookie) and
// `getAvatarHeadshotURL(userId:)` for the per-account avatar in the UI.
//
// The auth-ticket CSRF dance:
//   1. POST /v1/authentication-ticket with Cookie + Referer + Content-Type=application/json.
//      Roblox replies 403 with `x-csrf-token` header.
//   2. POST again, now with `X-CSRF-TOKEN: <value>` echoed.
//      Roblox replies 200 with `RBX-Authentication-Ticket` header.
// 415 on either call means we omitted Content-Type — that contract is
// load-bearing (caught at spike-time per RORORO Windows spec §5.7). Call
// out 415 distinctly so future-us doesn't waste cycles on a "401 cookie
// expired" red herring when the bug is actually a missing header.
//
// Test seam mirrors macRo's `LibraryStore.urlSessionForTesting` pattern:
// `nonisolated(unsafe)` is fine for single-writer test setUp/tearDown.

import Foundation

public enum RobloxApi {

    /// Auth-ticket endpoint — Roblox CSRF-dances all writes, this one
    /// included. Posts go directly here; no hidden /sign-in indirection.
    public static let authTicketEndpoint = URL(string: "https://auth.roblox.com/v1/authentication-ticket")!

    /// Required Referer per Roblox's CSRF check. Anything else 403s with a
    /// "Token Validation Failed" message instead of a usable csrf header.
    public static let referer = "https://www.roblox.com/"

    /// User-Agent. Honest about what we are; not pretending to be the
    /// Roblox launcher. The auth-ticket endpoint doesn't validate UA shape
    /// — only cookie + CSRF + Content-Type matter.
    public static let userAgent = "RORORO-Mac/0.0.1"

    public struct AuthTicket: Equatable, Sendable {
        public let ticket: String
        public let capturedAt: Date

        public init(ticket: String, capturedAt: Date) {
            self.ticket = ticket
            self.capturedAt = capturedAt
        }
    }

    public struct UserProfile: Equatable, Sendable {
        public let userId: Int64
        public let username: String
        public let displayName: String

        public init(userId: Int64, username: String, displayName: String) {
            self.userId = userId
            self.username = username
            self.displayName = displayName
        }
    }

    public struct GameMetadata: Equatable, Sendable {
        public let placeId: Int64
        public let universeId: Int64
        public let name: String
        public let iconURL: URL?

        public init(placeId: Int64, universeId: Int64, name: String, iconURL: URL?) {
            self.placeId = placeId
            self.universeId = universeId
            self.name = name
            self.iconURL = iconURL
        }
    }

    /// Result of resolving a `roblox.com/share?code=X&type=Server` token
    /// against Roblox's `sharelinks/v1/resolve-link` endpoint. Only valid
    /// for `linkType == "Server"` (private-server share links); other link
    /// types (Game / Profile) come back with placeId == 0.
    public struct ShareLinkResolution: Equatable, Sendable {
        public let linkType: String
        public let placeId: Int64
        public let linkCode: String

        public init(linkType: String, placeId: Int64, linkCode: String) {
            self.linkType = linkType
            self.placeId = placeId
            self.linkCode = linkCode
        }
    }

    public enum APIError: Error, Equatable {
        /// Roblox returned 401 — the user's `.ROBLOSECURITY` cookie is no
        /// longer valid. UI re-prompts for login.
        case cookieExpired
        /// 5xx from Roblox — caller can retry; not a permanent failure.
        case transient(status: Int)
        /// Anything else surprising. `message` contains a diagnostic hint
        /// (e.g. "missing X-CSRF-TOKEN header" or "missing Content-Type").
        case unexpected(status: Int, message: String)
    }

    /// Test seam — when set, all API calls run on this session. Tests
    /// install a stubbed `URLProtocol` configuration; production leaves nil.
    nonisolated(unsafe) public static var urlSessionForTesting: URLSession?

    private static var session: URLSession {
        urlSessionForTesting ?? URLSession.shared
    }

    /// Fetch a one-shot auth ticket for the given cookie. Performs the
    /// full CSRF dance. Throws `APIError.cookieExpired` if the cookie has
    /// expired; `.transient` on 5xx; `.unexpected` on protocol breakage.
    public static func getAuthTicket(cookie: String) async throws -> AuthTicket {
        guard !cookie.isEmpty else {
            throw APIError.unexpected(status: 0, message: "Cookie must not be empty.")
        }

        // First POST — discover the X-CSRF-TOKEN.
        let (firstStatus, firstHeaders, _) = try await postAuthTicket(cookie: cookie, csrfToken: nil)
        try mapFatalStatus(firstStatus)
        try checkContentTypeRejection(firstStatus)

        guard let csrfToken = headerValue(firstHeaders, name: "x-csrf-token"),
              !csrfToken.isEmpty else {
            throw APIError.unexpected(
                status: firstStatus,
                message: "Roblox auth-ticket endpoint did not return X-CSRF-TOKEN. Status=\(firstStatus)."
            )
        }

        // Second POST — exchange cookie + token for ticket.
        let (secondStatus, secondHeaders, _) = try await postAuthTicket(cookie: cookie, csrfToken: csrfToken)
        try mapFatalStatus(secondStatus)
        try checkContentTypeRejection(secondStatus)

        guard (200..<300).contains(secondStatus) else {
            throw APIError.unexpected(
                status: secondStatus,
                message: "Roblox auth-ticket endpoint returned \(secondStatus)."
            )
        }

        guard let ticket = headerValue(secondHeaders, name: "rbx-authentication-ticket"),
              !ticket.isEmpty else {
            throw APIError.unexpected(
                status: secondStatus,
                message: "Auth ticket response missing RBX-Authentication-Ticket header."
            )
        }

        return AuthTicket(ticket: ticket, capturedAt: Date())
    }

    /// Fetch the authenticated-user profile for the given cookie. Used by
    /// CookieCapture to populate Account fields after a fresh login. Throws
    /// `.cookieExpired` on 401, `.transient` on 5xx, `.unexpected` otherwise.
    public static func getUserProfile(cookie: String) async throws -> UserProfile {
        guard !cookie.isEmpty else {
            throw APIError.unexpected(status: 0, message: "Cookie must not be empty.")
        }

        var request = URLRequest(url: URL(string: "https://users.roblox.com/v1/users/authenticated")!)
        request.httpMethod = "GET"
        request.setValue(".ROBLOSECURITY=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.unexpected(status: 0, message: "Non-HTTP response from authenticated-user endpoint.")
        }
        try mapFatalStatus(http.statusCode)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.unexpected(
                status: http.statusCode,
                message: "Roblox authenticated-user endpoint returned \(http.statusCode)."
            )
        }

        do {
            let decoded = try JSONDecoder().decode(UserProfileResponse.self, from: data)
            return UserProfile(
                userId: decoded.id,
                username: decoded.name,
                displayName: decoded.displayName
            )
        } catch {
            throw APIError.unexpected(
                status: http.statusCode,
                message: "Failed to decode authenticated-user response: \(error.localizedDescription)"
            )
        }
    }

    /// Resolve a `roblox.com/share?code=X&type=Y` token against Roblox's
    /// `sharelinks/v1/resolve-link` endpoint. Used by AddPrivateServerSheet
    /// + LaunchTargetPicker when the user pastes the newer share-token URL
    /// form (the token is opaque locally — only this endpoint can turn it
    /// into the (placeId, linkCode) pair the launcher URI builder needs).
    ///
    /// Authenticated — needs a saved account's `.ROBLOSECURITY` cookie.
    /// Returns nil on resolve failure (token expired / wrong type / etc.).
    /// Throws `APIError.cookieExpired` on 401 so callers can prompt the user.
    public static func resolveShareLink(
        cookie: String,
        code: String,
        linkType: String = "Server"
    ) async throws -> ShareLinkResolution? {
        guard !cookie.isEmpty, !code.isEmpty else { return nil }
        let normalizedLinkType = linkType.isEmpty ? "Server" : linkType

        // Same CSRF dance as auth-ticket: first POST surfaces the token
        // (or returns 200 directly on tenants that skip the challenge),
        // second POST echoes it back.
        let body: [String: String] = ["linkId": code, "linkType": normalizedLinkType]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        let (firstStatus, firstHeaders, firstBody) = try await postShareLink(cookie: cookie, body: bodyData, csrfToken: nil)
        try mapFatalStatus(firstStatus)

        // 200 directly: parse + return.
        if (200..<300).contains(firstStatus) {
            return parseShareLinkResponse(firstBody, requestedLinkType: normalizedLinkType)
        }

        // 403 with x-csrf-token: do the second call.
        guard firstStatus == 403,
              let csrfToken = headerValue(firstHeaders, name: "x-csrf-token"),
              !csrfToken.isEmpty else {
            return nil
        }

        let (secondStatus, _, secondBody) = try await postShareLink(cookie: cookie, body: bodyData, csrfToken: csrfToken)
        try mapFatalStatus(secondStatus)
        guard (200..<300).contains(secondStatus) else { return nil }
        return parseShareLinkResponse(secondBody, requestedLinkType: normalizedLinkType)
    }

    /// Fetch metadata for a Roblox place by placeId. Three-call sequence
    /// matching the Windows port: place → universe → name → icon. Soft-fails
    /// any individual step (returns nil if place→universe fails; returns
    /// metadata with iconURL=nil if icons fail). Used by AddFavoriteSheet +
    /// AddPrivateServerSheet to enrich a paste with name + icon.
    public static func getGameMetadata(placeId: Int64) async throws -> GameMetadata? {
        guard placeId > 0 else { return nil }

        // Step 1: place id → universe id (public, no cookie).
        let universeURL = URL(string: "https://apis.roblox.com/universes/v1/places/\(placeId)/universe")!
        var universeRequest = URLRequest(url: universeURL)
        universeRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let universeId: Int64
        do {
            let (data, response) = try await session.data(for: universeRequest)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(UniverseLookupResponse.self, from: data)
            guard let id = decoded.universeId, id > 0 else { return nil }
            universeId = id
        } catch {
            return nil
        }

        // Step 2: universe id → game name (public, no cookie).
        let gamesURL = URL(string: "https://games.roblox.com/v1/games?universeIds=\(universeId)")!
        var gamesRequest = URLRequest(url: gamesURL)
        gamesRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let name: String
        do {
            let (data, response) = try await session.data(for: gamesRequest)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(GamesListResponse.self, from: data)
            guard let firstName = decoded.data.first?.name, !firstName.isEmpty else {
                return nil
            }
            name = firstName
        } catch {
            return nil
        }

        // Step 3: universe id → icon URL. Best-effort — return metadata with
        // iconURL=nil if this fails. Avatar/icon services are flakier than
        // the universe + games endpoints in practice.
        let iconURL: URL? = await {
            let urlString = "https://thumbnails.roblox.com/v1/games/icons"
                + "?universeIds=\(universeId)&size=150x150&format=Png&isCircular=false"
            guard let url = URL(string: urlString) else { return nil }
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    return nil
                }
                let decoded = try JSONDecoder().decode(GameIconsResponse.self, from: data)
                guard let imageUrl = decoded.data.first?.imageUrl, !imageUrl.isEmpty else {
                    return nil
                }
                return URL(string: imageUrl)
            } catch {
                return nil
            }
        }()

        return GameMetadata(
            placeId: placeId,
            universeId: universeId,
            name: name,
            iconURL: iconURL
        )
    }

    /// Fetch the avatar headshot URL for a user. Soft-fails — returns nil
    /// when the avatar service has nothing to offer rather than throwing.
    /// Callers treat the avatar as best-effort UI polish.
    public static func getAvatarHeadshotURL(userId: Int64) async throws -> URL? {
        guard userId > 0 else { return nil }

        let urlString =
            "https://thumbnails.roblox.com/v1/users/avatar-headshot"
            + "?userIds=\(userId)&size=150x150&format=Png&isCircular=false"
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        do {
            let decoded = try JSONDecoder().decode(AvatarHeadshotResponse.self, from: data)
            guard let imageUrl = decoded.data.first?.imageUrl, !imageUrl.isEmpty else {
                return nil
            }
            return URL(string: imageUrl)
        } catch {
            return nil
        }
    }

    // MARK: - Internals

    private struct UserProfileResponse: Decodable {
        let id: Int64
        let name: String
        let displayName: String
    }

    private struct AvatarHeadshotResponse: Decodable {
        let data: [Item]
        struct Item: Decodable {
            let imageUrl: String
        }
    }

    private struct UniverseLookupResponse: Decodable {
        let universeId: Int64?
    }

    private struct GamesListResponse: Decodable {
        let data: [Item]
        struct Item: Decodable {
            let name: String
        }
    }

    private struct GameIconsResponse: Decodable {
        let data: [Item]
        struct Item: Decodable {
            let imageUrl: String
        }
    }

    private static func postShareLink(
        cookie: String,
        body: Data,
        csrfToken: String?
    ) async throws -> (status: Int, headers: [AnyHashable: Any], body: Data) {
        var request = URLRequest(url: URL(string: "https://apis.roblox.com/sharelinks/v1/resolve-link")!)
        request.httpMethod = "POST"
        request.setValue(".ROBLOSECURITY=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let csrfToken, !csrfToken.isEmpty {
            request.setValue(csrfToken, forHTTPHeaderField: "X-CSRF-TOKEN")
        }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.unexpected(status: 0, message: "Non-HTTP response from sharelinks endpoint.")
        }
        return (http.statusCode, http.allHeaderFields, data)
    }

    private static func parseShareLinkResponse(_ data: Data, requestedLinkType: String) -> ShareLinkResolution? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let linkType = (json["linkType"] as? String) ?? requestedLinkType
        // Server kind: privateServerInviteData carries placeId + linkCode.
        // Status must be "Valid". Other types come back without invite data.
        if let invite = json["privateServerInviteData"] as? [String: Any],
           let status = invite["status"] as? String,
           status.caseInsensitiveCompare("Valid") == .orderedSame,
           let placeId = (invite["placeId"] as? Int64) ?? (invite["placeId"] as? Int).map(Int64.init),
           let linkCode = invite["linkCode"] as? String,
           placeId > 0,
           !linkCode.isEmpty {
            return ShareLinkResolution(linkType: linkType, placeId: placeId, linkCode: linkCode)
        }
        // Non-server link types or invalid invite data — return a zero
        // placeholder so callers can branch.
        return ShareLinkResolution(linkType: linkType, placeId: 0, linkCode: "")
    }

    private static func postAuthTicket(
        cookie: String,
        csrfToken: String?
    ) async throws -> (status: Int, headers: [AnyHashable: Any], body: Data) {
        var request = URLRequest(url: authTicketEndpoint)
        request.httpMethod = "POST"
        request.setValue(".ROBLOSECURITY=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Roblox returns 415 without explicit Content-Type even on empty bodies.
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let csrfToken, !csrfToken.isEmpty {
            request.setValue(csrfToken, forHTTPHeaderField: "X-CSRF-TOKEN")
        }
        request.httpBody = Data()

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.unexpected(status: 0, message: "Non-HTTP response from auth-ticket endpoint.")
        }
        return (http.statusCode, http.allHeaderFields, data)
    }

    private static func mapFatalStatus(_ status: Int) throws {
        switch status {
        case 401:
            throw APIError.cookieExpired
        case 500..<600:
            throw APIError.transient(status: status)
        default:
            return
        }
    }

    private static func checkContentTypeRejection(_ status: Int) throws {
        if status == 415 {
            throw APIError.unexpected(
                status: 415,
                message: "auth-ticket endpoint rejected Content-Type — Roblox requires Content-Type: application/json on these POSTs."
            )
        }
    }

    /// Case-insensitive header lookup. `HTTPURLResponse.allHeaderFields`
    /// preserves casing from the wire, which Roblox is inconsistent about
    /// (e.g. `RBX-Authentication-Ticket` vs `rbx-authentication-ticket`).
    private static func headerValue(_ headers: [AnyHashable: Any], name: String) -> String? {
        let lowerName = name.lowercased()
        for (key, value) in headers {
            if let keyString = key as? String, keyString.lowercased() == lowerName {
                return value as? String
            }
        }
        return nil
    }
}
