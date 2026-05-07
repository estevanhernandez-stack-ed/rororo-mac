// UpdateSettingsView.swift
// UI — Sparkle update controls. Embedded as a section inside SettingsView.
//
// Sections:
//   - Auto-check toggle (mirrors Sparkle's `automaticallyChecksForUpdates`)
//   - "Check for Updates Now" button
//   - Last-checked timestamp label
//
// Optional `updater` parameter covers the brief pre-.onAppear window where
// UpdaterHost hasn't booted yet. In practice the Settings sheet is
// unreachable until the main window is up, so the updater is non-nil
// at sheet-time.

import Sparkle
import SwiftUI

struct UpdateSettingsView: View {

    /// Live Sparkle updater. Optional to cover pre-.onAppear boot timing.
    let updater: SPUUpdater?

    /// Local mirror of Sparkle's `automaticallyChecksForUpdates`.
    @State private var automaticallyChecks: Bool = true

    /// Forces last-checked label refresh after manual checks.
    @State private var refreshTick: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Toggle(isOn: $automaticallyChecks) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatically check for updates")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Color.fg1)
                    Text("Daily check against the Sparkle appcast feed.")
                        .font(Theme.Font.bodySmall)
                        .foregroundStyle(Theme.Color.fg3)
                }
            }
            .toggleStyle(.switch)
            .disabled(updater == nil)
            .onChange(of: automaticallyChecks) { _, newValue in
                updater?.automaticallyChecksForUpdates = newValue
            }

            HStack(spacing: Theme.Spacing.md) {
                Button("Check for Updates Now") {
                    updater?.checkForUpdates()
                    refreshTick &+= 1
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Color.productTeal)
                .disabled(updater == nil || (updater?.canCheckForUpdates == false))

                Spacer()

                lastCheckedLabel
            }
        }
        .onAppear {
            if let updater {
                automaticallyChecks = updater.automaticallyChecksForUpdates
            }
        }
    }

    private var lastCheckedLabel: some View {
        let _ = refreshTick
        let formatted: String = {
            guard let updater, let date = updater.lastUpdateCheckDate else { return "Never" }
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return f.string(from: date)
        }()
        return Text("Last checked: \(formatted)")
            .font(Theme.Font.monoMicro)
            .tracking(0.12 * 11)
            .foregroundStyle(Theme.Color.fg3)
    }
}
