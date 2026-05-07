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

    var body: some View {
        AccountsListView(showAddAccount: $showAddAccount, showGames: $showGames)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    multiInstanceToggle
                    // .foregroundStyle on the BUTTON (not on the Label
                    // inside it) so the colored region matches the
                    // button's hit area; otherwise SwiftUI splits the
                    // hover region and .help() doesn't fire on the
                    // colored portion. .help() applied as the OUTERMOST
                    // modifier so it sees the full button tree.
                    Button {
                        showGames = true
                    } label: {
                        Label("Games", systemImage: "gamecontroller.fill")
                    }
                    .foregroundStyle(Theme.Color.productTeal)
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
        }
        .toggleStyle(.button)
        .foregroundStyle(state.enabled ? Theme.Color.brandCyan : Theme.Color.fg3)
        .help(
            state.enabled
                ? "Multi-instance ON — Launch As spawns a fresh Roblox window for each account. Click to disable."
                : "Multi-instance OFF — Launch As reuses the running Roblox window (single-instance). Click to enable multi-Roblox."
        )
    }
}
