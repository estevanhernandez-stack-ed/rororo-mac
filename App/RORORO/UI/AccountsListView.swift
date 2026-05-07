// AccountsListView.swift
// Account rows + "+ Add Account" button. Tapping Launch As fires the
// full RobloxLauncher.shared.launch(account:target:) flow. The `target`
// for v0.1.0 is always `.defaultGame` (resolved against FavoriteGameStore);
// the LaunchTargetEditor sheet (also Phase 5) lets users pick a specific
// place / private server / friend per launch.

import SwiftUI

struct AccountsListView: View {
    @Binding var showAddAccount: Bool

    @State private var inFlightLaunchUserId: String?
    @State private var lastLaunchError: String?
    @State private var pendingTargetForAccount: Account?
    @State private var showGameSettings: Bool = false
    @State private var defaultGameURL: String = FavoriteGameStore.shared.defaultGameURL

    private let accountStore = AccountStore.shared

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
        .sheet(item: $pendingTargetForAccount) { account in
            LaunchTargetEditor(account: account) { target in
                pendingTargetForAccount = nil
                launch(account: account, target: target)
            } onCancel: {
                pendingTargetForAccount = nil
            }
        }
        .sheet(isPresented: $showGameSettings) {
            GameSettingsSheet(defaultGameURL: $defaultGameURL, isPresented: $showGameSettings)
        }
    }

    /// Always-visible banner. Surfaces the current default game and the
    /// per-launch override path so users don't have to dig through Settings
    /// to discover them.
    private var defaultGameBanner: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "gamecontroller")
                .foregroundStyle(Theme.Color.brandCyan)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text("Default game")
                    .font(Theme.Font.monoMicro)
                    .tracking(1.2)
                    .foregroundStyle(Theme.Color.fg3)
                if defaultGameURL.isEmpty {
                    Text("Not set — Launch As will fail until you pick one.")
                        .font(Theme.Font.bodySmall)
                        .foregroundStyle(Theme.Color.stateWarn)
                } else {
                    Text(prettyDefaultGame(defaultGameURL))
                        .font(Theme.Font.bodySmall)
                        .foregroundStyle(Theme.Color.fg1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button(defaultGameURL.isEmpty ? "Set default" : "Change") {
                showGameSettings = true
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

    private func prettyDefaultGame(_ url: String) -> String {
        // Show a place name when we can parse one; fall back to the URL.
        if case let .place(placeId)? = LaunchTarget.fromUrl(url) {
            return "Place \(placeId)"
        }
        if case let .privateServer(placeId, _, kind)? = LaunchTarget.fromUrl(url) {
            return "Private server (\(kind == .linkCode ? "share link" : "access code")) on place \(placeId)"
        }
        return url
    }

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
                onLaunchDefault: { launch(account: account, target: .defaultGame) },
                onLaunchCustom: { pendingTargetForAccount = account },
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

    private func launch(account: Account, target: LaunchTarget) {
        inFlightLaunchUserId = account.userId
        Task { @MainActor in
            defer { inFlightLaunchUserId = nil }
            do {
                try await RobloxLauncher.shared.launch(account: account, target: target)
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
            return "No default game set. Open Settings and paste a Roblox game URL."
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
    let onLaunchDefault: () -> Void
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
                    Button("Launch As", action: onLaunchDefault)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.Color.productTeal)
                    Menu {
                        Button("Launch into specific game…", action: onLaunchCustom)
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
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    placeholderAvatar
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
