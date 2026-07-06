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

        // (4.5) Apply launch-time settings to Roblox's two write surfaces:
        //   - GlobalBasicSettings_<N>.xml (~/Library/Roblox/...) for FramerateCap
        //   - ClientAppSettings.json (inside Roblox.app bundle) for FFlags
        // Both are best-effort: the launch must not abort if either writer
        // fails. Per-account framerate override (Slope A3) wins over the
        // global LaunchSettingsStore cap when set; nil-override falls
        // back to the global. Cleanup of ClientAppSettings on Roblox
        // process exit is wired in MultiInstanceCoordinator.
        let snapshot = await MainActor.run {
            LaunchSettingsStore.shared.snapshot()
        }
        Self.applyLaunchSettings(snapshot: snapshot, account: account)

        // (5) Hand to coordinator on main. Pass the account's display
        // name so the per-launch bundle copy is named after the player
        // — surfaces in the Dock as the player's name instead of
        // "Roblox" or a UUID basename.
        guard let url = URL(string: uri) else {
            throw LauncherError.invalidLaunchURI
        }
        let displayLabel = account.displayName
        let userId = account.userId
        await MainActor.run {
            MultiInstanceCoordinator.shared.handleIncomingURL(
                url,
                displayLabel: displayLabel,
                userId: userId
            )
            AccountStore.shared.touchLastLaunched(userId: account.userId)
        }
    }

    /// Best-effort writer dispatch. Failures are logged and swallowed —
    /// the launch flow proceeds even if one or both writers can't run
    /// (Roblox not installed yet, file permissions wonky, etc.). Public
    /// for unit testing the dispatch logic; production callers go through
    /// `launch(account:target:)`.
    ///
    /// Effective frame-rate cap = `account.framerateCapOverride ??
    /// snapshot.framerateCap`. Per-account override wins when set;
    /// otherwise falls back to the global `LaunchSettingsStore` cap;
    /// nil at both levels means no XML write.
    public static func applyLaunchSettings(snapshot: LaunchSettingsStore.Snapshot, account: Account) {
        let effectiveCap = account.framerateCapOverride ?? snapshot.framerateCap
        applyLaunchSettings(snapshot: snapshot, effectiveCap: effectiveCap)
    }

    /// Variant for "no account context available" — applies globals only
    /// (global framerate cap + global FFlag set). Per-account overrides
    /// can't apply on this path.
    ///
    /// **Currently unused as of 2026-05-16.** Was previously called from
    /// `MultiInstanceCoordinator.handleIncomingURL` for external URL
    /// handoffs (`.onOpenURL` → coordinator). That path now always routes
    /// through an account-bound flow (`launchAsAccount` → `launch`), so
    /// every inbound URL has an account context by the time settings
    /// apply. See `docs/launch-via-link-per-account/design.md`.
    ///
    /// Kept (not deleted) as a safety net for future no-account entry
    /// points. If you add such an entry point, prefer routing through
    /// `launch(account:target:)` with a synthetic/default account if
    /// possible — `launch` does ticket re-mint + per-account writes and
    /// is the source of truth for "what should happen on a launch."
    public static func applyGlobalLaunchSettings(snapshot: LaunchSettingsStore.Snapshot) {
        applyLaunchSettings(snapshot: snapshot, effectiveCap: snapshot.framerateCap)
    }

    private static func applyLaunchSettings(snapshot: LaunchSettingsStore.Snapshot, effectiveCap: Int?) {
        if let effectiveCap {
            do {
                try GlobalSettingsWriter.setFramerateCap(effectiveCap)
            } catch {
                NSLog("[RORORO] GlobalSettingsWriter failed: \(error)")
            }
        }
        // Compute the effective fflag set: the active preset's bundle
        // (empty when no preset) merged with user-set fflags. User-set
        // values overlay the preset so explicit overrides win.
        let effectiveFlags = FFlagPresetLibrary.effectiveFlags(
            for: snapshot.activePreset,
            userOverrides: snapshot.fflags
        )
        if !effectiveFlags.isEmpty {
            let payload: [String: Any] = effectiveFlags.mapValues { $0.jsonObject }
            do {
                let outcome = try ClientSettingsWriter.write(flags: payload)
                if let preset = snapshot.activePreset {
                    NSLog("[RORORO] launch: FFlag preset '\(preset.rawValue)' active (\(effectiveFlags.count) fflags written)")
                }
                let recorded = LastAppliedFFlagsStore.Snapshot(
                    appliedAt: Date(),
                    activePreset: snapshot.activePreset,
                    flags: effectiveFlags,
                    outcome: String(describing: outcome)
                )
                Task { @MainActor in
                    LastAppliedFFlagsStore.shared.record(recorded)
                }
            } catch {
                NSLog("[RORORO] ClientSettingsWriter failed: \(error)")
            }
        }
    }

    @MainActor
    private static func resolveDefaultGame(_ target: LaunchTarget) throws -> LaunchTarget {
        if case .defaultGame = target {
            guard let resolved = currentDefaultTarget() else {
                throw LauncherError.unresolvedDefaultGame
            }
            return resolved
        }
        return target
    }

    /// The user's current "default launch target" — either a marked-default
    /// favorite or a marked-default saved private server. Used by the UI
    /// to drive the per-row Launch As primary button label + by
    /// `resolveDefaultGame` to convert `.defaultGame` to a concrete target.
    /// Returns nil when nothing is marked default.
    @MainActor
    public static func currentDefaultTarget() -> LaunchTarget? {
        if let fav = FavoriteGameStore.shared.defaultGame() {
            return .place(placeId: fav.placeId)
        }
        if let server = PrivateServerStore.shared.defaultServer() {
            return .privateServer(
                placeId: server.placeId,
                code: server.code,
                kind: server.codeKind
            )
        }
        return nil
    }

    /// Display name for the current default — favorite name OR private-
    /// server name. nil when no default is set.
    @MainActor
    public static func currentDefaultDisplayName() -> String? {
        if let fav = FavoriteGameStore.shared.defaultGame() {
            return fav.name
        }
        if let server = PrivateServerStore.shared.defaultServer() {
            return server.name
        }
        return nil
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
