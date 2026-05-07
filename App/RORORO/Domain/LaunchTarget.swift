// LaunchTarget.swift
// Domain — Discriminated union over what a Roblox launch is targeting.
//
// Ported from RORORO Windows (src/ROROROblox.Core/LaunchTarget.cs). Each
// variant maps to a distinct request= shape on Roblox's PlaceLauncher.ashx
// endpoint:
//   .defaultGame    → resolved at launch time via favorites + settings
//   .place          → request=RequestGame&placeId=X
//   .privateServer  → request=RequestPrivateGame&placeId=X&{linkCode|accessCode}=Y
//   .followFriend   → request=RequestFollowUser&userId=X
//
// The actual URL composition lives on RobloxLauncher (Phase 2). This file
// just shapes the value + parses user-pasted URLs.
//
// Cross-platform parity: byte-identical FromUrl semantics with the Windows
// port — same regex behavior, same private-server-code disambiguation, same
// nil returns. Account export/import between Windows and Mac depends on
// this staying in sync; if either side changes the parser, both ports must
// update together.

import Foundation

public enum LaunchTarget: Equatable, Sendable {
    /// Resolve from default favorite or app settings — original Launch As behavior.
    case defaultGame

    /// Public server, specific place. Used by the Games dialog.
    case place(placeId: Int64)

    /// VIP / private server. The two private-server code kinds are NOT
    /// interchangeable — `.linkCode` (share URL, server-side resolved at
    /// launch) goes in `linkCode=`; `.accessCode` (already-resolved
    /// launcher URI, e.g. browser-produced "Open in Roblox") goes in
    /// `accessCode=`. Sending the wrong code in the wrong slot returns
    /// permission-denied even when the user owns the server.
    case privateServer(placeId: Int64, code: String, kind: PrivateServerCodeKind)

    /// Follow a friend into whatever server they're in. Roblox does the
    /// permission check server-side; works for public AND private servers
    /// when the friend's privacy + server allowlist permit.
    case followFriend(userId: Int64)
}

/// Which Roblox query-param slot a private server's opaque code belongs in.
public enum PrivateServerCodeKind: Equatable, Sendable {
    /// Share URLs (the in-game "Configure server / Private Server Link" UI).
    /// Roblox resolves server-side at launch; emitted as `linkCode=`.
    case linkCode
    /// Already-resolved launcher URIs (browser-produced after clicking
    /// "Open in Roblox"). Emitted as `accessCode=`.
    case accessCode
}

extension LaunchTarget {
    /// Parsed result of the newer `roblox.com/share?code=X&type=Y` URL form.
    /// The token is opaque locally — only Roblox's `sharelinks/v1/resolve-link`
    /// API can turn it into a real `(placeId, linkCode)` pair. Callers feed
    /// both fields into `RobloxApi.resolveShareLink` (Phase 2) and build a
    /// `.privateServer` target from the result.
    public struct ShareLinkParse: Equatable, Sendable {
        public let code: String
        public let linkType: String

        public init(code: String, linkType: String) {
            self.code = code
            self.linkType = linkType
        }
    }

    /// Best-effort parse of any user-pasted Roblox URL into a launch target.
    /// Returns `nil` for unparseable input — callers should fall back to
    /// `.defaultGame` or surface an error.
    public static func fromUrl(_ input: String?) -> LaunchTarget? {
        guard let trimmed = trim(input), !trimmed.isEmpty else { return nil }

        // Bare numeric place id.
        if let bare = Int64(trimmed), bare > 0 {
            return .place(placeId: bare)
        }

        // Friend-follow profile URL: `roblox.com/users/<id>/profile` or
        // `roblox.com/users/<id>`. Resolves to `.followFriend(userId:)`
        // — the `RequestFollowUser` request flow on Roblox's launcher
        // endpoint, which respects the friend's privacy + server allowlist.
        if let userId = firstCaptureAsInt64(
            in: trimmed,
            pattern: #"roblox\.com/users/(\d+)"#
        ), userId > 0 {
            return .followFriend(userId: userId)
        }

        guard let placeId = firstCaptureAsInt64(
            in: trimmed,
            pattern: #"(?:placeId=|roblox\.com/games/)(\d+)"#
        ), placeId > 0 else {
            return nil
        }

        // Distinguish the two private-server code kinds. Share URLs carry
        // `privateServerLinkCode` / `linkCode`; already-resolved launcher
        // URIs carry `accessCode`. linkCode wins if both are present
        // (matches Windows port behavior + tests).
        if let linkCode = firstCapture(
            in: trimmed,
            pattern: #"(?:privateServerLinkCode|linkCode)=([A-Za-z0-9_\-]+)"#
        ), !linkCode.isEmpty {
            return .privateServer(placeId: placeId, code: linkCode, kind: .linkCode)
        }

        if let accessCode = firstCapture(
            in: trimmed,
            pattern: #"accessCode=([A-Za-z0-9_\-]+)"#
        ), !accessCode.isEmpty {
            return .privateServer(placeId: placeId, code: accessCode, kind: .accessCode)
        }

        return .place(placeId: placeId)
    }

    /// Detect Roblox's newer share-token URL form. The token is opaque
    /// locally; only Roblox's `sharelinks/v1/resolve-link` API can turn
    /// it into a real `(placeId, linkCode)` pair. Returns nil if the URL
    /// isn't a roblox.com/share URL or has no `code` param.
    public static func tryParseShareLink(_ input: String?) -> ShareLinkParse? {
        guard let trimmed = trim(input), !trimmed.isEmpty else { return nil }
        guard trimmed.range(of: "roblox.com/share", options: .caseInsensitive) != nil else {
            return nil
        }
        guard let code = firstCapture(
            in: trimmed,
            pattern: #"[?&]code=([A-Za-z0-9_\-]+)"#
        ), !code.isEmpty else {
            return nil
        }
        let linkType = firstCapture(
            in: trimmed,
            pattern: #"[?&]type=([A-Za-z]+)"#
        ) ?? "Server"
        return ShareLinkParse(code: code, linkType: linkType)
    }
}

// MARK: - Internals

private func trim(_ input: String?) -> String? {
    guard let input else { return nil }
    let stripped = input.trimmingCharacters(in: .whitespacesAndNewlines)
    return stripped.isEmpty ? nil : stripped
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

private func firstCaptureAsInt64(in input: String, pattern: String) -> Int64? {
    guard let captured = firstCapture(in: input, pattern: pattern) else { return nil }
    return Int64(captured)
}
