// AddPrivateServerSheet.swift
// Paste a private-server share link → parse to (placeId, code, kind) →
// fetch place metadata for the suggested name → user names the entry →
// save to PrivateServerStore.
//
// We DON'T accept the newer `roblox.com/share?code=X&type=Y` form here
// (those need an authenticated API call to resolve to a real placeId +
// linkCode pair — `LaunchTarget.tryParseShareLink` returns the opaque
// token, then the resolver hits Roblox's sharelinks endpoint with a
// cookie). v0.2 keeps it simple: paste the resolved share URL.

import SwiftUI

struct AddPrivateServerSheet: View {
    @Binding var isPresented: Bool

    @State private var pasted = ""
    @State private var name = ""
    @State private var fetchState: FetchState = .empty
    @State private var fetchTaskID = UUID()

    enum FetchState: Equatable {
        case empty
        case unparseable
        case fetching(placeId: Int64, code: String, kind: PrivateServerCodeKind)
        case ready(placeId: Int64, code: String, kind: PrivateServerCodeKind, metadata: RobloxApi.GameMetadata?)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack {
                Text("Add private server")
                    .font(Theme.Font.heading2)
                    .foregroundStyle(Theme.Color.fg1)
                Spacer()
                Button("Cancel") { isPresented = false }
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Share link".uppercased())
                    .font(Theme.Font.monoMicro)
                    .tracking(1.4)
                    .foregroundStyle(Theme.Color.fg3)

                Text("Paste a Roblox private-server share URL — `roblox.com/games/<id>?privateServerLinkCode=…` or an `accessCode=…` launcher URI.")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg2)

                TextField("https://www.roblox.com/games/…?privateServerLinkCode=…", text: $pasted)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: pasted) { _, newValue in
                        handlePasteChanged(newValue)
                    }

                preview
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Display name".uppercased())
                    .font(Theme.Font.monoMicro)
                    .tracking(1.4)
                    .foregroundStyle(Theme.Color.fg3)

                TextField("Friend group", text: $name)
                    .textFieldStyle(.roundedBorder)
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
        .frame(width: 540, height: 460)
        .background(Theme.Color.bgPage)
    }

    @ViewBuilder
    private var preview: some View {
        switch fetchState {
        case .empty:
            EmptyView()
        case .unparseable:
            previewBox(
                text: "Couldn't parse — paste a Roblox URL with a `privateServerLinkCode=` or `accessCode=` parameter.",
                color: Theme.Color.stateWarn
            )
        case .fetching(let placeId, _, let kind):
            previewBox(
                text: "Looking up place \(placeId) (\(kindLabel(kind)))…",
                color: Theme.Color.fg3
            )
        case .ready(let placeId, _, let kind, let metadata):
            HStack(spacing: Theme.Spacing.md) {
                thumbnail(metadata?.iconURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(metadata?.name ?? "Place \(placeId)")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Color.fg1)
                    Text("\(kindLabel(kind)) · place \(placeId)")
                        .font(Theme.Font.monoMicro)
                        .foregroundStyle(Theme.Color.fg3)
                }
                Spacer()
            }
            .padding(Theme.Spacing.sm)
            .background(Theme.Color.bgRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
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
                Image(systemName: "lock.shield")
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
        guard case .ready = fetchState else { return true }
        return name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func handlePasteChanged(_ newValue: String) {
        guard case .privateServer(let placeId, let code, let kind) = LaunchTarget.fromUrl(newValue) else {
            fetchState = newValue.isEmpty ? .empty : .unparseable
            return
        }
        fetchState = .fetching(placeId: placeId, code: code, kind: kind)
        let token = UUID()
        fetchTaskID = token
        Task { @MainActor in
            let metadata = try? await RobloxApi.getGameMetadata(placeId: placeId)
            guard fetchTaskID == token else { return }
            fetchState = .ready(placeId: placeId, code: code, kind: kind, metadata: metadata)
            // Pre-fill the display name with the place name as a starting point.
            // User can edit before saving.
            if name.trimmingCharacters(in: .whitespaces).isEmpty,
               let metadata {
                name = metadata.name
            }
        }
    }

    private func save() {
        guard case .ready(let placeId, let code, let kind, let metadata) = fetchState else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        PrivateServerStore.shared.add(
            placeId: placeId,
            code: code,
            codeKind: kind,
            name: trimmedName,
            placeName: metadata?.name ?? "",
            thumbnailURL: metadata?.iconURL
        )
        isPresented = false
    }

    private func kindLabel(_ kind: PrivateServerCodeKind) -> String {
        switch kind {
        case .linkCode: return "share-link code"
        case .accessCode: return "access code"
        }
    }
}
