// ContentView.swift
// Top-level window content. NavigationSplitView: sidebar with sections,
// detail showing the active section's view. v0.1.0 has a single section
// (Accounts); Settings + Diagnostics + About are sheets/popups.

import SwiftUI

struct ContentView: View {
    @State private var showSettings = false
    @State private var showAddAccount = false
    @State private var showDiagnostics = false
    @State private var showAbout = false
    @State private var showGames = false

    /// Observed so we can dismiss every open sheet the moment Sparkle
    /// decides there's a valid update — a presented SwiftUI sheet
    /// blocks `NSApp.terminate`, which Sparkle calls on
    /// "Install and Relaunch". See UpdaterHost for the full trap note.
    @ObservedObject private var updaterHost = UpdaterHost.shared

    var body: some View {
        AccountsListView(showAddAccount: $showAddAccount, showGames: $showGames)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    multiInstanceToggle
                    WindowLayoutToolbarView()
                    CyclerToolbarView()
                    // .foregroundStyle goes on the Label (not the Button)
                    // because SwiftUI toolbar Button styling doesn't
                    // propagate foreground color down to the label's
                    // systemImage — putting it on the outer Button leaves
                    // the icon system-tinted. .help() stays on the Button
                    // as the outermost modifier; macOS shows the tooltip
                    // after ~1–2s of stable hover (system default delay).
                    Button {
                        showGames = true
                    } label: {
                        Label("Games", systemImage: "gamecontroller.fill")
                            .foregroundStyle(Theme.Color.productTeal)
                    }
                    .help("Games — manage favorite games and saved private servers")

                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .help("Settings — multi-instance toggle, updates")

                    Menu {
                        Button("Diagnostics") { showDiagnostics = true }
                        Button("About RORORO") { showAbout = true }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .help("Diagnostics + About")
                }
            }
            .sheet(isPresented: $showGames) {
                GamesView(isPresented: $showGames)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .frame(minWidth: 480, minHeight: 360)
            }
            .sheet(isPresented: $showAddAccount) {
                AddAccountSheet(isPresented: $showAddAccount)
            }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsView(isPresented: $showDiagnostics)
                    .frame(minWidth: 480, minHeight: 480)
            }
            .sheet(isPresented: $showAbout) {
                AboutView(isPresented: $showAbout)
                    .frame(width: 420, height: 420)
            }
            .background(Theme.Color.bgPage)
            .onChange(of: updaterHost.hasUpdateAvailable) { _, newValue in
                guard newValue else { return }
                // Dismiss every sheet so Sparkle's update window has a
                // clean main window to terminate against. Order doesn't
                // matter — they're independent state bindings.
                showSettings = false
                showDiagnostics = false
                showGames = false
                showAddAccount = false
                showAbout = false
                updaterHost.acknowledgeUpdateAvailable()
            }
    }

    private var multiInstanceToggle: some View {
        let state = MultiInstanceState.shared
        return Toggle(isOn: Binding(
            get: { state.enabled },
            set: { state.enabled = $0 }
        )) {
            Label(
                "Multi-instance",
                systemImage: state.enabled ? "square.stack.3d.up.fill" : "square.stack.3d.up"
            )
            .foregroundStyle(state.enabled ? Theme.Color.brandCyan : Theme.Color.fg3)
        }
        .toggleStyle(.button)
        .help(
            state.enabled
                ? "Multi-instance ON — Launch As spawns a fresh Roblox window for each account. Click to disable."
                : "Multi-instance OFF — Launch As reuses the running Roblox window (single-instance). Click to enable multi-Roblox."
        )
    }
}
