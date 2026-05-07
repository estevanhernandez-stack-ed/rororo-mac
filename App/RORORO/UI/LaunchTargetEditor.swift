// LaunchTargetEditor.swift
// Sheet that lets users pick a specific game / private server / friend
// for a one-off launch (overrides the default game from FavoriteGameStore).
// Paste a Roblox URL or a bare numeric place id; the parser disambiguates.

import SwiftUI

struct LaunchTargetEditor: View {
    let account: Account
    let onLaunch: (LaunchTarget) -> Void
    let onCancel: () -> Void

    @State private var pasted: String = ""
    @State private var preview: LaunchTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Launch As \(account.displayName)")
                .font(Theme.Font.heading2)
                .foregroundStyle(Theme.Color.fg1)

            Text("Paste a Roblox game URL, private server share link, or bare place ID. Leave blank to use your default game.")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg2)

            TextField("https://www.roblox.com/games/…", text: $pasted)
                .textFieldStyle(.roundedBorder)
                .onChange(of: pasted) { _, newValue in
                    preview = LaunchTarget.fromUrl(newValue)
                }

            if let preview {
                previewLine(preview)
            }

            Spacer()

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Launch") {
                    onLaunch(preview ?? .defaultGame)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.Color.productTeal)
                .disabled(!pasted.isEmpty && preview == nil)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 480, height: 280)
        .background(Theme.Color.bgPage)
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
        case .defaultGame:
            return "Default game"
        case .place(let id):
            return "Place \(id)"
        case .privateServer(let id, _, let kind):
            return "Private server (\(kind == .linkCode ? "share link" : "access code")) on place \(id)"
        case .followFriend(let id):
            return "Follow user \(id)"
        }
    }
}
