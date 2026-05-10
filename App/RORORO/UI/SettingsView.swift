// SettingsView.swift
// Multi-instance toggle + frame-rate cap + danger zone.
// Persists via MultiInstanceState + LaunchSettingsStore — both back to
// UserDefaults, so settings survive app relaunch.

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var multiInstanceEnabled = MultiInstanceState.shared.enabled
    @State private var dangerZoneVisible = false

    @ObservedObject private var launchSettings = LaunchSettingsStore.shared
    @State private var framerateCapEnabled: Bool
    @State private var framerateCapValue: Int
    @State private var lowResourceModeEnabled: Bool

    init() {
        let initialCap = LaunchSettingsStore.shared.framerateCap
        _framerateCapEnabled = State(initialValue: initialCap != nil)
        _framerateCapValue = State(initialValue: initialCap ?? 20)
        _lowResourceModeEnabled = State(initialValue: LaunchSettingsStore.shared.lowResourceMode)
    }

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

            section("Frame rate") {
                Toggle("Throttle Roblox FPS at launch", isOn: $framerateCapEnabled)
                    .onChange(of: framerateCapEnabled) { _, newValue in
                        if newValue {
                            launchSettings.setFramerateCap(framerateCapValue)
                        } else {
                            launchSettings.setFramerateCap(nil)
                        }
                    }
                if framerateCapEnabled {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text("Cap")
                            .font(Theme.Font.bodySmall)
                            .foregroundStyle(Theme.Color.fg2)
                        Picker("Cap", selection: $framerateCapValue) {
                            Text("20 fps").tag(20)
                            Text("30 fps").tag(30)
                            Text("60 fps").tag(60)
                            Text("144 fps").tag(144)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: framerateCapValue) { _, newValue in
                            if framerateCapEnabled {
                                launchSettings.setFramerateCap(newValue)
                            }
                        }
                    }
                }
                Text(framerateCapEnabled
                     ? "Roblox-wide cap. Every running instance is throttled at this rate uniformly — applied at next launch. Already-running instances keep their current cap until restart."
                     : "Default: Roblox uses its built-in 60 fps cap.")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg3)
            }

            section("Low-resource mode") {
                Toggle("Inject low-resource FFlag bundle at launch", isOn: $lowResourceModeEnabled)
                    .onChange(of: lowResourceModeEnabled) { _, newValue in
                        launchSettings.setLowResourceMode(newValue)
                    }
                Text(lowResourceModeEnabled
                     ? "ON: voxel lighting, post-FX off, no shadows/grass/wind, lowest texture quality, telemetry disabled. Cuts CPU + GPU + RAM for AFK / multi-instance grinding. User-set FFlags overlay on top so explicit overrides win. Hyperion may silently no-op some — bench actual deltas before trusting."
                     : "Default: Roblox renders at the game's quality settings.")
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
        .frame(minWidth: 480, minHeight: 420)
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
