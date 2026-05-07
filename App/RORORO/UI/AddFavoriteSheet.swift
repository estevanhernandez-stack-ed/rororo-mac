// AddFavoriteSheet.swift
// Paste a Roblox game URL → parse → fetch metadata (name + icon) → save
// to FavoriteGameStore. Empty fetch state, in-flight, error, and ready
// previews are all rendered inline so the user knows what'll be saved
// before they hit the button.

import SwiftUI

struct AddFavoriteSheet: View {
    @Binding var isPresented: Bool

    @State private var pasted = ""
    @State private var fetchState: FetchState = .empty
    @State private var fetchTaskID = UUID()

    enum FetchState: Equatable {
        case empty
        case unparseable
        case fetching(placeId: Int64)
        case ready(RobloxApi.GameMetadata)
        case fetchFailed(placeId: Int64)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack {
                Text("Add favorite game")
                    .font(Theme.Font.heading2)
                    .foregroundStyle(Theme.Color.fg1)
                Spacer()
                Button("Cancel") { isPresented = false }
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Paste a Roblox game URL or a bare numeric place id.")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg2)

                TextField("https://www.roblox.com/games/…", text: $pasted)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: pasted) { _, newValue in
                        handlePasteChanged(newValue)
                    }

                preview
            }

            Spacer()

            HStack {
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Color.productTeal)
                    .disabled(saveDisabled)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 540, height: 360)
        .background(Theme.Color.bgPage)
    }

    @ViewBuilder
    private var preview: some View {
        switch fetchState {
        case .empty:
            EmptyView()
        case .unparseable:
            previewBox(text: "Couldn't parse — paste a roblox.com/games/… URL or a numeric place id.",
                       color: Theme.Color.stateWarn)
        case .fetching(let placeId):
            previewBox(text: "Looking up place \(placeId)…", color: Theme.Color.fg3)
        case .ready(let metadata):
            HStack(spacing: Theme.Spacing.md) {
                thumbnail(metadata.iconURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(metadata.name)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Color.fg1)
                    Text("Place \(metadata.placeId) · universe \(metadata.universeId)")
                        .font(Theme.Font.monoMicro)
                        .foregroundStyle(Theme.Color.fg3)
                }
                Spacer()
            }
            .padding(Theme.Spacing.sm)
            .background(Theme.Color.bgRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
        case .fetchFailed(let placeId):
            previewBox(
                text: "Place \(placeId) found but metadata lookup failed. You can save it anyway — name will say \"Place \(placeId)\".",
                color: Theme.Color.stateWarn
            )
        }
    }

    private func thumbnail(_ url: URL?) -> some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.sm)
            .fill(Theme.Color.bgSurface)
            .overlay(
                Image(systemName: "gamecontroller")
                    .foregroundStyle(Theme.Color.fg3)
            )
    }

    private func previewBox(text: String, color: SwiftUI.Color) -> some View {
        Text(text)
            .font(Theme.Font.bodySmall)
            .foregroundStyle(color)
            .padding(Theme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Color.bgRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    private var saveDisabled: Bool {
        switch fetchState {
        case .ready, .fetchFailed: return false
        default: return true
        }
    }

    private func handlePasteChanged(_ newValue: String) {
        let placeId = parsePlaceId(newValue)
        guard let placeId else {
            fetchState = newValue.isEmpty ? .empty : .unparseable
            return
        }
        fetchState = .fetching(placeId: placeId)
        let token = UUID()
        fetchTaskID = token
        Task { @MainActor in
            let metadata = try? await RobloxApi.getGameMetadata(placeId: placeId)
            // Stale-result guard: if the user kept typing, ignore us.
            guard fetchTaskID == token else { return }
            if let metadata {
                fetchState = .ready(metadata)
            } else {
                fetchState = .fetchFailed(placeId: placeId)
            }
        }
    }

    private func parsePlaceId(_ input: String) -> Int64? {
        guard case .place(let placeId)? = LaunchTarget.fromUrl(input) else {
            return RobloxLauncher.extractPlaceId(input)
        }
        return placeId
    }

    private func save() {
        switch fetchState {
        case .ready(let metadata):
            FavoriteGameStore.shared.add(
                placeId: metadata.placeId,
                universeId: metadata.universeId,
                name: metadata.name,
                thumbnailURL: metadata.iconURL
            )
        case .fetchFailed(let placeId):
            FavoriteGameStore.shared.add(
                placeId: placeId,
                universeId: 0,
                name: "Place \(placeId)",
                thumbnailURL: nil
            )
        default: return
        }
        isPresented = false
    }
}
