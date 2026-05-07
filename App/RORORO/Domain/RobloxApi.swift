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
