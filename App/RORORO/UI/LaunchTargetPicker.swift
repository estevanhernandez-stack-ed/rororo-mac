// LaunchTargetPicker.swift
// Replaces the v0.1 LaunchTargetEditor (paste-only). Shows the user's
// saved favorites + saved private servers as picker rows, plus a custom
// URL paste at the bottom for one-off targets that aren't saved.
//
// Used by AccountsListView when a user invokes "Launch into specific
// game…" from the per-row ⋯ menu, and as the fallback when hybrid
// Launch As has no default favorite to default into.

import SwiftUI

struct LaunchTargetPicker: View {
    let account: Account
    let onLaunch: (LaunchTarget, _ savedServerId: UUID?) -> Void
    let onCancel: () -> Void

    @State private var customURL = ""
    @State private var customPreview: LaunchTarget?

    private let favoriteStore = FavoriteGameStore.shared
    private let serverStore = PrivateServerStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack {
                Text("Launch As \(account.displayName)")
                    .font(Theme.Font.heading2)
                    .foregroundStyle(Theme.Color.fg1)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if !favoriteStore.favorites.isEmpty {
                        section("Favorite games") {
                            ForEach(favoriteStore.favorites) { game in
                                pickerRow(
                                    iconURL: game.thumbnailURL,
                                    placeholderSystemImage: "gamecontroller",
                                    title: game.name,
                                    subtitle: "Place \(game.placeId)\(game.isDefault ? " · default" : "")",
                                    action: {
                                        onLaunch(.place(placeId: game.placeId), nil)
                                    }
                                )
                            }
                        }
                    }

                    if !serverStore.servers.isEmpty {
                        section("Saved private servers") {
                            ForEach(serverStore.servers) { server in
                                pickerRow(
                                    iconURL: server.thumbnailURL,
                                    placeholderSystemImage: "lock.shield",
                                    title: server.name,
                                    subtitle: serverSubtitle(server),
                                    action: {
                                        onLaunch(
                                            .privateServer(
                                                placeId: server.placeId,
                                                code: server.code,
                                                kind: server.codeKind
                                            ),
                                            server.id
                                        )
                                    }
                                )
                            }
                        }
                    }

                    section("Custom URL") {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            TextField(
                                "https://www.roblox.com/games/… or share-link URL",
                                text: $customURL
                            )
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: customURL) { _, newValue in
                                customPreview = LaunchTarget.fromUrl(newValue)
                            }

                            if let target = customPreview {
                                HStack {
                                    Text(describe(target))
                                        .font(Theme.Font.mono)
                                        .foregroundStyle(Theme.Color.fg2)
                                    Spacer()
                                    Button("Launch") {
                                        onLaunch(target, nil)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Theme.Color.productTeal)
                                }
                            } else if !customURL.isEmpty {
                                Text("Couldn't parse — paste a Roblox URL or numeric place id.")
                                    .font(Theme.Font.bodySmall)
                                    .foregroundStyle(Theme.Color.stateWarn)
                            }
                        }
                    }

                    if favoriteStore.favorites.isEmpty && serverStore.servers.isEmpty {
                        Text("No favorite games or saved private servers yet. Click Games in the toolbar to add one, then Launch As will land here.")
                            .font(Theme.Font.bodySmall)
                            .foregroundStyle(Theme.Color.fg3)
                            .padding(Theme.Spacing.md)
                    }
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 540, height: 540)
        .background(Theme.Color.bgPage)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title.uppercased())
                .font(Theme.Font.monoMicro)
                .tracking(1.4)
                .foregroundStyle(Theme.Color.fg3)
            content()
        }
    }

    private func pickerRow(
        iconURL: URL?,
        placeholderSystemImage: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.md) {
                thumbnail(iconURL: iconURL, placeholder: placeholderSystemImage)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Color.fg1)
                    Text(subtitle)
                        .font(Theme.Font.monoMicro)
                        .foregroundStyle(Theme.Color.fg3)
                }
                Spacer()
                Image(systemName: "play.fill")
                    .foregroundStyle(Theme.Color.productTeal)
            }
            .padding(Theme.Spacing.sm)
            .background(Theme.Color.bgSurface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func thumbnail(iconURL: URL?, placeholder: String) -> some View {
        Group {
            if let iconURL {
                AsyncImage(url: iconURL) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: placeholderView(systemImage: placeholder)
                    }
                }
            } else {
                placeholderView(systemImage: placeholder)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    private func placeholderView(systemImage: String) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.sm)
            .fill(Theme.Color.bgRaised)
            .overlay(
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.Color.fg3)
            )
    }

    private func serverSubtitle(_ server: SavedPrivateServer) -> String {
        let kindLabel = server.codeKind == .linkCode ? "share link" : "access code"
        if server.placeName.isEmpty {
            return "Place \(server.placeId) · \(kindLabel)"
        }
        return "\(server.placeName) · \(kindLabel)"
    }

    private func describe(_ target: LaunchTarget) -> String {
        switch target {
        case .defaultGame: return "Default game"
        case .place(let id): return "Place \(id)"
        case .privateServer(let id, _, let kind):
            return "Private server (\(kind == .linkCode ? "share link" : "access code")) on place \(id)"
        case .followFriend(let id): return "Follow user \(id)"
        }
    }
}
