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

    /// Always-visible banner. Reads directly from FavoriteGameStore.shared
    /// (an @Observable singleton) so it updates whenever a default is set
    /// or cleared in GamesView.
    private var defaultGameBanner: some View {
        let defaultGame = favoriteStore.defaultGame()
        return HStack(spacing: Theme.Spacing.md) {
            bannerIcon(for: defaultGame)
            VStack(alignment: .leading, spacing: 2) {
                Text("Default game")
                    .font(Theme.Font.monoMicro)
                    .tracking(1.2)
                    .foregroundStyle(Theme.Color.fg3)
                if let defaultGame {
                    Text(defaultGame.name)
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
            Button(defaultGame == nil ? "Set up" : "Manage") {
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

    @ViewBuilder
    private func bannerIcon(for game: FavoriteGame?) -> some View {
        if let url = game?.thumbnailURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: bannerIconPlaceholder
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            bannerIconPlaceholder
                .frame(width: 28, height: 28)
        }
    }

    private var bannerIconPlaceholder: some View {
        Image(systemName: "gamecontroller")
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
        List(accountStore.accounts) { account in
            AccountRow(
                account: account,
                isLaunching: inFlightLaunchUserId == account.userId,
                onLaunchPrimary: { launchPrimary(account: account) },
                onLaunchCustom: { pendingPickerForAccount = account },
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
    let onLaunchPrimary: () -> Void
    let onLaunchCustom: () -> Void
    let onRemove: () -> Void

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
                if let last = account.lastLaunchedAt {
                    Text("Last launched \(last.formatted(.relative(presentation: .named)))")
                        .font(Theme.Font.monoMicro)
                        .foregroundStyle(Theme.Color.fg3)
                }
            }
            Spacer()
            if isLaunching {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: Theme.Spacing.xs) {
                    Button("Launch As", action: onLaunchPrimary)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.Color.productTeal)
                    Menu {
                        Button("Pick game / server…", action: onLaunchCustom)
                        Divider()
                        Button("Remove account", role: .destructive, action: onRemove)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
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
