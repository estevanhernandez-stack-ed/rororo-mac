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
    @State private var showFFlags = false

    init() {
        let initialCap = LaunchSettingsStore.shared.framerateCap
        _framerateCapEnabled = State(initialValue: initialCap != nil)
        _framerateCapValue = State(initialValue: initialCap ?? 20)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(Theme.Font.heading1)
                .foregroundStyle(Theme.Color.fg1)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.md)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
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
                             ? "Roblox-wide cap by default — per-account overrides (set on the account row) win when present. Applied at next launch; already-running instances keep their current cap until restart."
                             : "Default: Roblox uses its built-in 60 fps cap. Per-account overrides (set on the account row) can still set a cap for individual accounts.")
                            .font(Theme.Font.bodySmall)
                            .foregroundStyle(Theme.Color.fg3)
                    }

                    section("FFlags") {
                        Button {
                            showFFlags = true
                        } label: {
                            Label("Open FFlags editor…", systemImage: "flag.2.crossed")
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.Color.productTeal)
                        Text(fflagsSummary)
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
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.lg)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Color.productTeal)
            }
            .padding(Theme.Spacing.lg)
        }
        .frame(minWidth: 480, minHeight: 520, idealHeight: 600)
        .background(Theme.Color.bgPage)
        .sheet(isPresented: $showFFlags) {
            FFlagsSheet(isPresented: $showFFlags)
        }
    }

    /// One-line state summary for the FFlags Settings row. `launchSettings`
    /// is already an @ObservedObject, so this recomputes when the preset
    /// or overrides change.
    private var fflagsSummary: String {
        let presetName: String
        if let id = launchSettings.activePreset,
           let preset = FFlagPresetLibrary.preset(id) {
            presetName = preset.displayName
        } else {
            presetName = "None"
        }
        let count = launchSettings.fflags.count
        let overrides = count == 1 ? "1 override" : "\(count) overrides"
        return "Preset: \(presetName) · \(overrides). Global — every Roblox instance, applied at launch."
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
