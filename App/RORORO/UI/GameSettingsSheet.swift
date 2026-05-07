// GameSettingsSheet.swift
// Inline games-management sheet — wraps FavoriteGameStore so users don't
// have to dig through the full Settings sheet to set the default game.
// v0.1.0 ships a single default game URL; v0.2 will grow this into a
// multi-game favorites list (matches the Windows port's FavoriteGameStore).

import SwiftUI

struct GameSettingsSheet: View {
    @Binding var defaultGameURL: String
    @Binding var isPresented: Bool

    @State private var draft: String = ""
    @State private var preview: LaunchTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack {
                Text("Games")
                    .font(Theme.Font.heading2)
                    .foregroundStyle(Theme.Color.fg1)
                Spacer()
                Button("Close") { isPresented = false }
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Default game".uppercased())
                    .font(Theme.Font.monoMicro)
                    .tracking(1.4)
                    .foregroundStyle(Theme.Color.fg3)

                Text("This is what Launch As opens when you tap a saved account. Paste a Roblox game URL or private-server share link. Override per-launch from any account row's ⋯ menu.")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg2)

                TextField("https://www.roblox.com/games/…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draft) { _, newValue in
                        preview = LaunchTarget.fromUrl(newValue)
                    }

                if !draft.isEmpty {
                    if let preview {
                        previewLine(preview)
                    } else {
                        Text("Couldn't parse that URL. Roblox game / private-server share link / bare numeric place id.")
                            .font(Theme.Font.bodySmall)
                            .foregroundStyle(Theme.Color.stateWarn)
                    }
                }
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Saved private servers".uppercased())
                    .font(Theme.Font.monoMicro)
                    .tracking(1.4)
                    .foregroundStyle(Theme.Color.fg3)

                Text("Coming in v0.2. For now: paste a private-server share link into the box above for a one-shot launch, or set it as the default if it's where you spend most of your time.")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg3)
                    .padding(Theme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Color.bgRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }

            Spacer()

            HStack {
                Spacer()
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.Color.productTeal)
                .disabled(!draft.isEmpty && preview == nil)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 540, height: 540)
        .background(Theme.Color.bgPage)
        .onAppear {
            draft = defaultGameURL
            preview = LaunchTarget.fromUrl(draft)
        }
    }

    private func save() {
        FavoriteGameStore.shared.defaultGameURL = draft
        defaultGameURL = draft
        isPresented = false
    }

    private func previewLine(_ target: LaunchTarget) -> some View {
        Text(describe(target))
            .font(Theme.Font.mono)
            .foregroundStyle(Theme.Color.fg2)
            .padding(Theme.Spacing.sm)
            .background(Theme.Color.bgRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
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
