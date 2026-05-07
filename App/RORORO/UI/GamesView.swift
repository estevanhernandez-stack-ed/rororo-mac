// GamesView.swift
// Tabbed UI replacing the v0.1 GameSettingsSheet stub. Two tabs:
//   - Favorites: list of saved games + Set Default + Remove + Add
//   - Private servers: list of saved share-links + Remove + Add
//
// Reads/writes through `FavoriteGameStore.shared` + `PrivateServerStore.shared`
// (both @Observable @MainActor singletons) — list updates flow back to
// AccountsListView's banner without explicit coordination.

import SwiftUI

struct GamesView: View {
    @Binding var isPresented: Bool

    @State private var selected: Tab = .favorites
    @State private var showAddFavorite = false
    @State private var showAddPrivateServer = false
    @State private var renameTarget: RenameTarget?

    private enum Tab: Hashable { case favorites, privateServers }

    /// Identifier-with-payload for the rename sheet. Identifiable so
    /// .sheet(item:) opens fresh per-target. fileprivate so the
    /// RenameSheet at file scope can reference the enum cases.
    fileprivate enum RenameTarget: Identifiable, Equatable {
        case favorite(placeId: Int64, currentName: String)
        case server(id: UUID, currentName: String)

        var id: String {
            switch self {
            case .favorite(let placeId, _): return "fav-\(placeId)"
            case .server(let serverId, _): return "ps-\(serverId.uuidString)"
            }
        }
    }

    private let favoriteStore = FavoriteGameStore.shared
    private let serverStore = PrivateServerStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                Text("Games")
                    .font(Theme.Font.heading1)
                    .foregroundStyle(Theme.Color.fg1)
                Spacer()
                Button("Close") { isPresented = false }
            }

            Picker("", selection: $selected) {
                Text("Favorites").tag(Tab.favorites)
                Text("Private servers").tag(Tab.privateServers)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch selected {
                case .favorites: favoritesTab
                case .privateServers: privateServersTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(Theme.Spacing.lg)
        .frame(minWidth: 540, minHeight: 540)
        .background(Theme.Color.bgPage)
        .sheet(isPresented: $showAddFavorite) {
            AddFavoriteSheet(isPresented: $showAddFavorite)
        }
        .sheet(isPresented: $showAddPrivateServer) {
            AddPrivateServerSheet(isPresented: $showAddPrivateServer)
        }
        .sheet(item: $renameTarget) { target in
            RenameSheet(target: target) { newName in
                applyRename(target: target, newName: newName)
                renameTarget = nil
            } onCancel: {
                renameTarget = nil
            }
        }
    }

    private func applyRename(target: RenameTarget, newName: String) {
        switch target {
        case .favorite(let placeId, _):
            favoriteStore.rename(placeId: placeId, to: newName)
        case .server(let serverId, _):
            serverStore.rename(id: serverId, to: newName)
        }
    }

    // MARK: - Favorites tab

    private var favoritesTab: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if favoriteStore.favorites.isEmpty {
                emptyFavorites
            } else {
                favoritesList
            }
            Spacer()
            Button {
                showAddFavorite = true
            } label: {
                Label("Add favorite", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Color.productTeal)
        }
    }

    private var emptyFavorites: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 36))
                .foregroundStyle(Theme.Color.fg3)
            Text("No favorite games yet")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.fg1)
            Text("Add a Roblox game URL — Launch As will land your accounts there. Mark one as default for one-click launches.")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var favoritesList: some View {
        List {
            ForEach(favoriteStore.favorites) { game in
                FavoriteRow(
                    game: game,
                    onSetDefault: { favoriteStore.setDefault(placeId: game.placeId) },
                    onRename: {
                        renameTarget = .favorite(placeId: game.placeId, currentName: game.name)
                    },
                    onRemove: { favoriteStore.remove(placeId: game.placeId) }
                )
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Private servers tab

    private var privateServersTab: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if serverStore.servers.isEmpty {
                emptyServers
            } else {
                serversList
            }
            Spacer()
            Button {
                showAddPrivateServer = true
            } label: {
                Label("Add private server", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Color.productTeal)
        }
    }

    private var emptyServers: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(Theme.Color.fg3)
            Text("No saved private servers yet")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.fg1)
            Text("Paste a private-server share link and give it a name. Launch any account into any saved server from the per-row Launch As menu.")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var serversList: some View {
        List {
            ForEach(serverStore.servers) { server in
                PrivateServerRow(
                    server: server,
                    onRename: {
                        renameTarget = .server(id: server.id, currentName: server.name)
                    },
                    onRemove: { serverStore.remove(id: server.id) }
                )
            }
        }
        .listStyle(.inset)
    }
}

// MARK: - RenameSheet

private struct RenameSheet: View {
    let target: GamesView.RenameTarget
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Rename")
                .font(Theme.Font.heading2)
                .foregroundStyle(Theme.Color.fg1)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(label.uppercased())
                    .font(Theme.Font.monoMicro)
                    .tracking(1.4)
                    .foregroundStyle(Theme.Color.fg3)

                TextField("Display name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commit() }
            }

            Spacer()

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Color.productTeal)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 420, height: 220)
        .background(Theme.Color.bgPage)
        .onAppear {
            draft = currentName
        }
    }

    private var label: String {
        switch target {
        case .favorite: return "Favorite name"
        case .server: return "Private-server name"
        }
    }

    private var currentName: String {
        switch target {
        case .favorite(_, let name), .server(_, let name): return name
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }
}

// MARK: - Rows

private struct FavoriteRow: View {
    let game: FavoriteGame
    let onSetDefault: () -> Void
    let onRename: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(game.name)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Color.fg1)
                    if game.isDefault {
                        Text("DEFAULT")
                            .font(Theme.Font.monoMicro)
                            .tracking(1.2)
                            .foregroundStyle(Theme.Color.productTeal)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Theme.Color.productTeal, lineWidth: 1)
                            )
                    }
                }
                Text("Place \(game.placeId)")
                    .font(Theme.Font.monoMicro)
                    .foregroundStyle(Theme.Color.fg3)
            }
            Spacer()
            // Visible Rename button — discoverable surface for the action
            // users can't intuit from a `⋯` menu alone (caught at v0.2
            // smoke 2026-05-07).
            Button(action: onRename) {
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Color.fg2)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Rename")

            Menu {
                if !game.isDefault {
                    Button("Set as default", action: onSetDefault)
                }
                Divider()
                Button("Remove", role: .destructive, action: onRemove)
            } label: {
                // contentShape(Rectangle()) on the explicit frame fixes
                // the v0.1.x "haunted ⋯" — without it, only the glyph
                // pixels were hit-testable and clicks frequently missed.
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Color.fg2)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = game.thumbnailURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: placeholder
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        } else {
            placeholder.frame(width: 44, height: 44)
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.sm)
            .fill(Theme.Color.bgRaised)
            .overlay(
                Image(systemName: "gamecontroller")
                    .foregroundStyle(Theme.Color.fg3)
            )
    }
}

private struct PrivateServerRow: View {
    let server: SavedPrivateServer
    let onRename: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.fg1)
                Text(subtitle)
                    .font(Theme.Font.monoMicro)
                    .foregroundStyle(Theme.Color.fg3)
            }
            Spacer()
            Button(action: onRename) {
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Color.fg2)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Rename")

            Menu {
                Button("Remove", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Color.fg2)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private var subtitle: String {
        let kindLabel = server.codeKind == .linkCode ? "share link" : "access code"
        if server.placeName.isEmpty {
            return "Place \(server.placeId) · \(kindLabel)"
        }
        return "\(server.placeName) · \(kindLabel)"
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = server.thumbnailURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: placeholder
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        } else {
            placeholder.frame(width: 44, height: 44)
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.sm)
            .fill(Theme.Color.bgRaised)
            .overlay(
                Image(systemName: "lock.shield")
                    .foregroundStyle(Theme.Color.fg3)
            )
    }
}
