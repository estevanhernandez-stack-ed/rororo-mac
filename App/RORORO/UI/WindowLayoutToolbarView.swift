// WindowLayoutToolbarView.swift
// UI — toolbar Menu for the Window Layout Tool (Slope D wave 1,
// ADR 0005). Sits between the Multi-instance toggle and the Cycler in
// `ContentView`. Tile submenu enabled in P1; Shrink + Custom items
// present but disabled (P2).
//
// Cycler-state reactive disable: while AutoKeysCyclerViewModel.shared
// is .running, every action item is disabled with a tooltip pointing
// at the cycler's Stop button.

import SwiftUI

struct WindowLayoutToolbarView: View {

    @State private var vm = WindowLayoutViewModel.shared
    @State private var cyclerVM = AutoKeysCyclerViewModel.shared

    var body: some View {
        Menu {
            // P1.5: include externally-launched Roblox windows in the
            // pid set so users can tile/shrink a pre-existing grinding
            // session without having to relaunch via RORORO. External
            // windows still don't get accounts/auto-keys/relogin —
            // window mgmt only.
            Button {
                vm.includeExternalWindows.toggle()
            } label: {
                Label(
                    vm.includeExternalWindows
                        ? "✓ Include external windows"
                        : "Include external windows",
                    systemImage: "rectangle.stack.badge.plus"
                )
            }
            .help("When ON, Tile/Shrink also moves Roblox windows that weren't launched by RORORO. They don't become accounts.")
            Divider()
            tileSection
            Divider()
            shrinkSection
            Divider()
            Button("Custom Size…") { /* P2 */ }
                .disabled(true)
                .help("Coming soon — custom size slider lands in P2.")
        } label: {
            Label("Layout", systemImage: "rectangle.3.offgrid")
                .foregroundStyle(Theme.Color.fg2)
        }
        .menuStyle(.borderlessButton)
        .help(menuHelp)
        .alert(
            "Window Layout",
            isPresented: Binding(
                get: { vm.lastError != nil },
                set: { newValue in if !newValue { vm.clearError() } }
            )
        ) {
            if let msg = vm.lastError, msg.contains("Accessibility") {
                Button("Open Settings") {
                    AutoKeysPermissions.openAccessibilitySettings()
                    vm.clearError()
                }
            }
            Button("OK") { vm.clearError() }
        } message: {
            Text(vm.lastError ?? "")
        }
    }

    // MARK: - sections

    @ViewBuilder
    private var tileSection: some View {
        Menu("Tile") {
            Button("Auto-grid") {
                Task { await vm.applyAutoGrid() }
            }
            .disabled(cyclerIsRunning)
            Divider()
            Button("2 × 2") {
                Task { await vm.applyGrid(cols: 2, rows: 2) }
            }
            .disabled(cyclerIsRunning)
            Button("3 × 3") {
                Task { await vm.applyGrid(cols: 3, rows: 3) }
            }
            .disabled(cyclerIsRunning)
            Divider()
            Button("Row (1 × N)") {
                Task {
                    let n = max(1, RunningAccountTracker.shared.pidsByUserId.count)
                    await vm.applyGrid(cols: n, rows: 1)
                }
            }
            .disabled(cyclerIsRunning)
            Button("Column (N × 1)") {
                Task {
                    let n = max(1, RunningAccountTracker.shared.pidsByUserId.count)
                    await vm.applyGrid(cols: 1, rows: n)
                }
            }
            .disabled(cyclerIsRunning)
        }
    }

    @ViewBuilder
    private var shrinkSection: some View {
        Menu("Shrink") {
            Button("25%") {
                Task { await vm.applyShrink(percent: 0.25) }
            }
            .disabled(cyclerIsRunning)
            Button("50%") {
                Task { await vm.applyShrink(percent: 0.50) }
            }
            .disabled(cyclerIsRunning)
            Button("75%") {
                Task { await vm.applyShrink(percent: 0.75) }
            }
            .disabled(cyclerIsRunning)
            Button("100% (restore)") {
                Task { await vm.applyShrink(percent: 1.0) }
            }
            .disabled(cyclerIsRunning)
        }
        .help("Shrink each window proportionally around its current center.")
    }

    // MARK: - state

    private var cyclerIsRunning: Bool {
        if case .running = cyclerVM.state { return true }
        return false
    }

    private var menuHelp: String {
        cyclerIsRunning
            ? "Stop auto-keys to rearrange windows."
            : "Tile or resize all running Roblox windows."
    }
}
