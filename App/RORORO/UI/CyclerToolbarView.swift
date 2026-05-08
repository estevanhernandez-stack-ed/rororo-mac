// CyclerToolbarView.swift
// Toolbar item + paused banner for the auto-keys cycler (Slope C wave
// 3b, ADR 0004 Decisions 6 + 9). The toolbar surfaces:
//   - Play / Pause / Resume button (driven by AutoKeysCyclerViewModel.state)
//   - Live cycle estimate, color-coded by CycleBudget.State
//   - Persistent "running" indicator while .running
// On Play, if safety isn't yet configured the toolbar opens the
// AutoKeysSafetySetupSheet first; only after that closes does the
// cycler kick off.

import SwiftUI

struct CyclerToolbarView: View {

    @State private var vm = AutoKeysCyclerViewModel.shared
    @State private var showSafetySetup: Bool = false
    @State private var showAlert: Bool = false

    private let settings = LaunchSettingsStore.shared

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            estimateLabel
            primaryButton
        }
        .sheet(isPresented: $showSafetySetup) {
            AutoKeysSafetySetupSheet(isPresented: $showSafetySetup)
        }
        .onAppear {
            vm.refreshEstimate()
        }
        .alert(
            "Auto-keys",
            isPresented: Binding(
                get: { vm.preflightMessage != nil || vm.lastError != nil },
                set: { _ in /* clear handled by buttons */ }
            )
        ) {
            Button("Open Settings") {
                if vm.preflightMessage?.contains("Accessibility") == true {
                    AutoKeysPermissions.openAccessibilitySettings()
                } else if vm.preflightMessage?.contains("Input Monitoring") == true {
                    AutoKeysPermissions.openInputMonitoringSettings()
                }
            }
            Button("OK") { /* dismiss */ }
        } message: {
            Text(vm.preflightMessage ?? vm.lastError ?? "")
        }
    }

    // MARK: - Subviews

    private var primaryButton: some View {
        Button {
            primaryAction()
        } label: {
            Label(buttonLabel, systemImage: buttonIcon)
                .foregroundStyle(buttonColor)
        }
        .help(buttonHelp)
    }

    private var estimateLabel: some View {
        HStack(spacing: 4) {
            if isRunning {
                Circle()
                    .fill(Theme.Color.brandCyan)
                    .frame(width: 6, height: 6)
            }
            Text(estimateText)
                .font(Theme.Font.monoMicro)
                .foregroundStyle(estimateColor)
                .tracking(0.4)
        }
    }

    // MARK: - State helpers

    private var isRunning: Bool {
        if case .running = vm.state { return true }
        return false
    }

    private var isPaused: Bool {
        if case .paused = vm.state { return true }
        return false
    }

    private var buttonLabel: String {
        switch vm.state {
        case .stopped: return "Auto-keys"
        case .running: return "Pause"
        case .paused(.userRequested, _):  return "Resume"
        case .paused(.userEngaged, _):    return "Stop"
        }
    }

    private var buttonIcon: String {
        switch vm.state {
        case .stopped:                    return "play.circle"
        case .running:                    return "pause.circle.fill"
        case .paused(.userRequested, _):  return "play.circle.fill"
        case .paused(.userEngaged, _):    return "stop.circle.fill"
        }
    }

    private var buttonColor: Color {
        switch vm.state {
        case .stopped:                    return Theme.Color.fg2
        case .running:                    return Theme.Color.brandCyan
        case .paused(.userRequested, _):  return Theme.Color.stateInfo
        case .paused(.userEngaged, _):    return Theme.Color.stateWarn
        }
    }

    private var buttonHelp: String {
        switch vm.state {
        case .stopped:
            return "Start auto-keys. Builds a snapshot from running accounts that have a sequence configured."
        case .running:
            return "Pause auto-keys. Cycler stops firing; resume resumes from the next iteration."
        case .paused(.userRequested, _):
            return "Resume auto-keys."
        case .paused(.userEngaged, _):
            return "Cycler paused — you moved the mouse / typed. Will auto-resume in a few seconds. Click to stop instead."
        }
    }

    private var estimateText: String {
        if vm.lastEstimate <= 0 {
            return "—"
        }
        let mins = Int(vm.lastEstimate) / 60
        let secs = Int(vm.lastEstimate) % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }

    private var estimateColor: Color {
        switch CycleBudget.state(for: vm.lastEstimate) {
        case .ok:      return Theme.Color.fg3
        case .warn:    return Theme.Color.stateWarn
        case .overCap: return Theme.Color.stateDanger
        }
    }

    // MARK: - Actions

    private func primaryAction() {
        switch vm.state {
        case .stopped:
            // Gate behind safety setup: if the user has never configured
            // a kill key + gesture, surface the setup sheet first.
            // (LaunchSettingsStore returns the default config out of the
            // box, but the user opting into the feature should explicitly
            // confirm the kill key + gesture choice — UX intent.)
            if !hasConfiguredSafety() {
                showSafetySetup = true
                return
            }
            Task { await vm.play() }
        case .running:
            Task { await vm.pause() }
        case .paused(.userRequested, _):
            Task { await vm.resume() }
        case .paused(.userEngaged, _):
            Task { await vm.stop() }
        }
    }

    /// Heuristic: if the safety config still equals the bare default
    /// (F19 + hold-1s + 5s) AND the user has never touched it, prompt
    /// the setup. Once they save anything (even re-saving the defaults),
    /// `setAutoKeysSafety` writes to UserDefaults and the key exists,
    /// which we read indirectly by checking… actually simpler: write
    /// a marker on first save.
    private func hasConfiguredSafety() -> Bool {
        // Treat any explicit save as having configured. Default config
        // is what we ship; users opt-in via the setup sheet.
        UserDefaults.standard.bool(forKey: "rororo.autoKeys.safety.configured")
    }
}
