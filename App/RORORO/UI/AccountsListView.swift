// AccountsListView.swift
// Account rows + "+ Add Account" button + a persistent default-game banner.
//
// Hybrid Launch As (per-row primary button):
//   - If FavoriteGameStore has a default favorite → launch into that.
//   - Otherwise → open the LaunchTargetPicker so the user picks (or
//     pastes a custom URL).
//
// Per-row ⋯ menu always opens LaunchTargetPicker for explicit overrides.

import SwiftUI

struct AccountsListView: View {
    @Binding var showAddAccount: Bool
    @Binding var showGames: Bool

    @State private var inFlightLaunchUserId: String?
    @State private var lastLaunchError: String?
    @State private var pendingPickerForAccount: Account?

    private let accountStore = AccountStore.shared
    private let favoriteStore = FavoriteGameStore.shared
    private let serverStore = PrivateServerStore.shared

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                defaultGameBanner
                Group {
                    if accountStore.accounts.isEmpty {
                        emptyState
                    } else {
                        accountList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            addAccountButton
                .padding(Theme.Spacing.lg)
        }
        .alert("Launch failed", isPresented: Binding(
            get: { lastLaunchError != nil },
            set: { _ in lastLaunchError = nil }
        )) {
            Button("OK") { lastLaunchError = nil }
        } message: {
            Text(lastLaunchError ?? "")
        }
        .sheet(item: $pendingPickerForAccount) { account in
            LaunchTargetPicker(
                account: account,
                onLaunch: { target, savedServerId in
                    pendingPickerForAccount = nil
                    launch(account: account, target: target, savedServerId: savedServerId)
                },
                onCancel: {
                    pendingPickerForAccount = nil
                }
            )
        }
    }

    // MARK: - Banner

    /// Always-visible banner. Resolves the current default across BOTH
    /// FavoriteGameStore and PrivateServerStore — the marked-default
    /// entry can be either a favorite game or a saved private server.
    private var defaultGameBanner: some View {
        let target = bannerTarget()
        return HStack(spacing: Theme.Spacing.md) {
            bannerIcon(target: target)
            VStack(alignment: .leading, spacing: 2) {
                Text("Default launch target")
                    .font(Theme.Font.monoMicro)
                    .tracking(1.2)
                    .foregroundStyle(Theme.Color.fg3)
                if let target {
                    Text(target.name)
                        .font(Theme.Font.bodySmall)
                        .foregroundStyle(Theme.Color.fg1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Not set — Launch As will open a picker.")
                        .font(Theme.Font.bodySmall)
                        .foregroundStyle(Theme.Color.stateWarn)
                }
            }
            Spacer()
            Button(target == nil ? "Set up" : "Manage") {
                showGames = true
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.Color.bgSurface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.Color.bgRaised)
                .frame(height: 1)
        }
    }

    private struct BannerTarget {
        let name: String
        let thumbnailURL: URL?
        let kind: Kind
        enum Kind { case favorite, privateServer }
    }

    private func bannerTarget() -> BannerTarget? {
        if let fav = favoriteStore.defaultGame() {
            return BannerTarget(name: fav.name, thumbnailURL: fav.thumbnailURL, kind: .favorite)
        }
        if let server = serverStore.defaultServer() {
            return BannerTarget(name: server.name, thumbnailURL: server.thumbnailURL, kind: .privateServer)
        }
        return nil
    }

    @ViewBuilder
    private func bannerIcon(target: BannerTarget?) -> some View {
        if let url = target?.thumbnailURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: bannerIconPlaceholder(kind: target?.kind)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            bannerIconPlaceholder(kind: target?.kind)
                .frame(width: 28, height: 28)
        }
    }

    private func bannerIconPlaceholder(kind: BannerTarget.Kind?) -> some View {
        Image(systemName: kind == .privateServer ? "lock.shield" : "gamecontroller")
            .foregroundStyle(Theme.Color.brandCyan)
            .imageScale(.large)
    }

    // MARK: - List + empty

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(Theme.Color.fg3)
            Text("No saved accounts")
                .font(Theme.Font.heading2)
                .foregroundStyle(Theme.Color.fg1)
            Text("Add a Roblox account to start launching with one click.")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button {
                showAddAccount = true
            } label: {
                Label("Add Account", systemImage: "plus")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(Theme.Color.productTeal)
        }
        .padding(Theme.Spacing.xl)
    }

    private var accountList: some View {
        let defaultName = RobloxLauncher.currentDefaultDisplayName()
        return List(accountStore.accounts) { account in
            AccountRow(
                account: account,
                isLaunching: inFlightLaunchUserId == account.userId,
                defaultDisplayName: defaultName,
                favorites: favoriteStore.favorites,
                servers: serverStore.servers,
                onLaunchPrimary: { launchPrimary(account: account) },
                onPickFavorite: { game in
                    favoriteStore.setDefault(placeId: game.placeId)
                    launch(account: account, target: .place(placeId: game.placeId), savedServerId: nil)
                },
                onPickServer: { server in
                    serverStore.setDefault(id: server.id)
                    launch(
                        account: account,
                        target: .privateServer(
                            placeId: server.placeId,
                            code: server.code,
                            kind: server.codeKind
                        ),
                        savedServerId: server.id
                    )
                },
                onLaunchCustom: { pendingPickerForAccount = account },
                onSetFramerateCap: { cap in
                    accountStore.setFramerateCapOverride(userId: account.userId, cap: cap)
                },
                onRemove: { remove(account: account) }
            )
        }
        .listStyle(.inset)
    }

    private var addAccountButton: some View {
        Button {
            showAddAccount = true
        } label: {
            Label("Add Account", systemImage: "plus")
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(Theme.Color.productTeal)
    }

    // MARK: - Launch flow

    /// Hybrid behavior: if a default favorite is set, launch into it
    /// immediately; otherwise open the picker.
    private func launchPrimary(account: Account) {
        if FavoriteGameStore.shared.defaultGame() != nil {
            launch(account: account, target: .defaultGame, savedServerId: nil)
        } else {
            pendingPickerForAccount = account
        }
    }

    private func launch(account: Account, target: LaunchTarget, savedServerId: UUID?) {
        inFlightLaunchUserId = account.userId
        Task { @MainActor in
            defer { inFlightLaunchUserId = nil }
            do {
                try await RobloxLauncher.shared.launch(account: account, target: target)
                if let savedServerId {
                    PrivateServerStore.shared.touchLastLaunched(id: savedServerId)
                }
            } catch let error as RobloxApi.APIError {
                // Mark the cookie expired in AccountStore so the row
                // UI surfaces the badge BEFORE the next click attempt
                // (Slope B3′). RobloxLauncher's getAuthTicket converts
                // a 401 into APIError.cookieExpired; we trust that
                // signal here.
                if case .cookieExpired = error {
                    accountStore.setCookieStatus(userId: account.userId, status: .expired)
                }
                lastLaunchError = describe(apiError: error)
            } catch let error as RobloxLauncher.LauncherError {
                lastLaunchError = describe(launcherError: error)
            } catch {
                lastLaunchError = error.localizedDescription
            }
        }
    }

    private func remove(account: Account) {
        do {
            try accountStore.remove(userId: account.userId)
        } catch {
            lastLaunchError = "Failed to remove account: \(error.localizedDescription)"
        }
    }

    private func describe(apiError: RobloxApi.APIError) -> String {
        switch apiError {
        case .cookieExpired:
            return "This account's login expired. Remove and re-add it."
        case .transient(let status):
            return "Roblox is having trouble (HTTP \(status)). Try again in a moment."
        case .unexpected(_, let message):
            return message
        }
    }

    private func describe(launcherError: RobloxLauncher.LauncherError) -> String {
        switch launcherError {
        case .unresolvedDefaultGame:
            return "No default game set. Click Games in the toolbar to add one."
        case .cookieMissing(let userId):
            return "No cookie stored for account \(userId). Remove and re-add the account."
        case .invalidLaunchURI:
            return "Could not build the launch URI. Please report this."
        case .invalidTarget(let reason):
            return "Invalid target: \(reason)"
        case .emptyTicket, .emptyPlaceURL, .emptyBrowserTrackerId:
            return "Internal error building the launch URI. Please report this."
        }
    }
}

private struct AccountRow: View {
    let account: Account
    let isLaunching: Bool
    let defaultDisplayName: String?
    let favorites: [FavoriteGame]
    let servers: [SavedPrivateServer]
    let onLaunchPrimary: () -> Void
    let onPickFavorite: (FavoriteGame) -> Void
    let onPickServer: (SavedPrivateServer) -> Void
    let onLaunchCustom: () -> Void
    let onSetFramerateCap: (Int?) -> Void
    let onRemove: () -> Void

    /// Frame-rate cap options surfaced in the per-account menu. nil =
    /// "Use global" (fall back to LaunchSettingsStore.shared.framerateCap).
    private static let framerateCapOptions: [Int] = [20, 30, 60, 144]

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.fg1)
                Text("@\(account.username)")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg3)
                if account.cookieStatus == .expired {
                    // Slope B3′ — surface cookie expiry per-row so
                    // users see the rot before they click Launch As
                    // and hit a generic alert. Boot-time probe in
                    // App.onAppear refreshes this; launch-time
                    // .cookieExpired catch in AccountsListView.launch
                    // also marks expired live.
                    Text("Login expired — needs re-login")
                        .font(Theme.Font.monoMicro)
                        .foregroundStyle(Theme.Color.stateDanger)
                } else if let last = account.lastLaunchedAt {
                    Text("Last launched \(last.formatted(.relative(presentation: .named)))")
                        .font(Theme.Font.monoMicro)
                        .foregroundStyle(Theme.Color.fg3)
                }
            }
            Spacer()
            if isLaunching {
                ProgressView().controlSize(.small)
            } else {
                splitLaunchButton
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    /// Visual: one continuous brand gradient (cyan → teal) containing
    /// the primary label and a chevron dropdown. No divider — the chevron
    /// sits on the same surface, distinguished by its glyph + smaller pad.
    /// Hairline outer border keeps it readable against the dark row surface.
    ///
    /// Picking from the dropdown sets the chosen target as the new
    /// cross-store default AND launches it — one click, persistent. The
    /// banner + primary label both reflect the new default thereafter.
    private var splitLaunchButton: some View {
        HStack(spacing: 0) {
            Button(action: onLaunchPrimary) {
                Text(primaryLabel)
                    .font(Theme.Font.bodySmall)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .padding(.leading, 12)
                    .padding(.trailing, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Per-account framerate override badge. Only rendered when
            // the account has an explicit override — accounts using the
            // global setting (or with no cap at all) get no badge, so
            // the row stays clean for users not engaged with per-account
            // throttling. Renders on the same gradient as the primary
            // button + chevron, distinguished by mono-micro size.
            if let cap = account.framerateCapOverride {
                Text("\(cap)FPS")
                    .font(Theme.Font.monoMicro)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .tracking(0.5)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .accessibilityLabel("Per-account framerate cap: \(cap) frames per second")
            }

            Menu {
                Button("Launch into default", action: onLaunchPrimary)
                    .disabled(defaultDisplayName == nil)
                if !favorites.isEmpty {
                    Section("Favorite games") {
                        ForEach(favorites) { game in
                            Button(game.isDefault ? "\(game.name) — current default" : game.name) {
                                onPickFavorite(game)
                            }
                        }
                    }
                }
                if !servers.isEmpty {
                    Section("Saved private servers") {
                        ForEach(servers) { server in
                            Button(server.isDefault ? "\(server.name) — current default" : server.name) {
                                onPickServer(server)
                            }
                        }
                    }
                }
                if !favorites.isEmpty || !servers.isEmpty {
                    Divider()
                }
                Button("Pick game / server…", action: onLaunchCustom)
                Divider()
                Section("Frame rate cap (this account)") {
                    Button(account.framerateCapOverride == nil
                           ? "✓ Use global"
                           : "Use global") {
                        onSetFramerateCap(nil)
                    }
                    ForEach(Self.framerateCapOptions, id: \.self) { value in
                        Button(account.framerateCapOverride == value
                               ? "✓ \(value) fps"
                               : "\(value) fps") {
                            onSetFramerateCap(value)
                        }
                    }
                }
                Divider()
                Button("Remove account", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .padding(.trailing, 10)
                    .padding(.leading, 4)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
        }
        .background(
            LinearGradient(
                colors: [Theme.Color.brandCyan, Theme.Color.productTeal],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
        )
    }

    /// Primary button text — short. Long target names blew up the row
    /// width at v0.2 manual smoke; the dropdown items already show the
    /// full target name, so this just communicates "we're targeting the
    /// default" without naming it.
    private var primaryLabel: String {
        defaultDisplayName != nil ? "Launch As default" : "Launch As"
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = account.avatarThumbnailURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: placeholderAvatar
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
        } else {
            placeholderAvatar
        }
    }

    private var placeholderAvatar: some View {
        Circle()
            .fill(Theme.Color.bgRaised)
            .frame(width: 44, height: 44)
            .overlay(
                Text(String(account.displayName.prefix(1)))
                    .font(Theme.Font.heading2)
                    .foregroundStyle(Theme.Color.fg2)
            )
    }
}
