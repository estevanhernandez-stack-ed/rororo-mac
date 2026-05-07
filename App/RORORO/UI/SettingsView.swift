// SettingsView.swift
// Multi-instance toggle + default game URL + danger zone (cookie copy).
// Persists via MultiInstanceState + FavoriteGameStore — both back to
// UserDefaults, so settings survive app relaunch.

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var multiInstanceEnabled = MultiInstanceState.shared.enabled
    @State private var defaultGameURL = FavoriteGameStore.shared.defaultGameURL
    @State private var dangerZoneVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Settings")
                .font(Theme.Font.heading1)
                .foregroundStyle(Theme.Color.fg1)

            section("Multi-instance") {
                Toggle("Allow multiple Roblox windows", isOn: $multiInstanceEnabled)
                    .onChange(of: multiInstanceEnabled) { _, newValue in
                        MultiInstanceState.shared.enabled = newValue
                    }
                Text(multiInstanceEnabled
                     ? "Each Launch As spawns a fresh Roblox instance via per-launch app copy + sem_unlink."
                     : "Multi-instance OFF: launches go to /Applications/Roblox.app and only one Roblox window can run at a time.")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg3)
            }

            section("Default game") {
                TextField("https://www.roblox.com/games/…", text: $defaultGameURL)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: defaultGameURL) { _, newValue in
                        FavoriteGameStore.shared.defaultGameURL = newValue
                    }
                Text("When you tap Launch As without a specific game, RORORO opens this URL.")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg3)
            }

            section("Updates") {
                UpdateSettingsView(updater: UpdaterHost.shared.updater)
            }

            DisclosureGroup("Danger zone", isExpanded: $dangerZoneVisible) {
                Text("Future surface for sensitive operations (e.g. exporting cookies for sibling apps). Off in v0.1.0.")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg3)
                    .padding(.top, Theme.Spacing.xs)
            }
            .font(Theme.Font.bodySmall)

            Spacer()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Color.productTeal)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(minWidth: 480, minHeight: 360)
        .background(Theme.Color.bgPage)
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title.uppercased())
                .font(Theme.Font.monoMicro)
                .foregroundStyle(Theme.Color.fg3)
                .tracking(1.4)
            content()
        }
    }
}
