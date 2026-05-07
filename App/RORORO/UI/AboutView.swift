// AboutView.swift
// Version + license + provenance. Provenance line credits MultiBloxy
// (Windows mutex technique) and Insadem (macOS sem_unlink technique).
// Every release ships with this surface so the credit stays load-bearing.

import SwiftUI

struct AboutView: View {
    @Binding var isPresented: Bool

    private var version: String {
        let bundle = Bundle.main
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Text("RORORO")
                .font(Theme.Font.display)
                .foregroundStyle(Theme.Color.fg1)

            Text("Mac-native multi-Roblox launcher")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg2)

            Text(version)
                .font(Theme.Font.mono)
                .foregroundStyle(Theme.Color.fg3)

            Spacer()

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Provenance".uppercased())
                    .font(Theme.Font.monoMicro)
                    .foregroundStyle(Theme.Color.fg3)
                    .tracking(1.4)
                Text("Multi-instance technique: MultiBloxy (Windows mutex) and Insadem multi-roblox-macos (macOS POSIX sem_unlink). Reimplemented in Swift; no code copied.")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("MIT License — © 2026 626 Labs LLC")
                .font(Theme.Font.monoMicro)
                .foregroundStyle(Theme.Color.fg3)

            Button("Close") { isPresented = false }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.bordered)
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 380, height: 320)
        .background(Theme.Color.bgPage)
    }
}
