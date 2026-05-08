// AutoKeysRecorderSheet.swift
// Modal recorder for one account's auto-keys sequence (Slope C wave 3b,
// ADR 0004 Decision 5). Step-by-step capture: press a key, set the
// delay-after, optionally add 1-2 more steps, save. Up to 3 steps.
//
// Live cycle preview (`CycleBudget.estimate`) shows whether saving the
// current sequence keeps the global cycle under the warn / hard cap.
// Save disables when over cap.

import AppKit
import CoreGraphics
import SwiftUI

struct AutoKeysRecorderSheet: View {

    @Binding var isPresented: Bool
    let account: Account

    private let store = AccountStore.shared
    private let settings = LaunchSettingsStore.shared

    @State private var draftSteps: [AutoKeysStep] = []
    @State private var capturingKey: Bool = false
    @State private var pendingKeyCode: CGKeyCode? = nil
    @State private var pendingDelaySeconds: Double = 2.0
    @State private var pendingDelayUnit: DelayUnit = .seconds

    private enum DelayUnit: String, CaseIterable, Identifiable {
        case seconds, minutes
        var id: String { rawValue }
        var label: String { self == .seconds ? "sec" : "min" }
        var multiplier: Double { self == .seconds ? 1 : 60 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            header

            divider

            stepsList

            divider

            captureSection

            Spacer(minLength: 0)

            cyclePreview

            footer
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 520, height: 600)
        .background(Theme.Color.bgPage)
        .onAppear {
            if let existing = account.autoKeys {
                draftSteps = existing.steps
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Auto-keys for \(account.displayName)")
                .font(Theme.Font.heading2)
                .foregroundStyle(Theme.Color.fg1)
            Text("Up to 3 keys. Each fires in order, with the delay you set before the cycler moves on.")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg2)
        }
    }

    private var stepsList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Sequence (\(draftSteps.count) of \(AutoKeysSequence.maxSteps))")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg2)
                .textCase(.uppercase)
                .tracking(0.7)

            if draftSteps.isEmpty {
                Text("No steps yet. Press the capture button below to record your first key.")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg3)
            } else {
                ForEach(Array(draftSteps.enumerated()), id: \.offset) { idx, step in
                    HStack(spacing: Theme.Spacing.md) {
                        Text("\(idx + 1).")
                            .font(Theme.Font.mono)
                            .foregroundStyle(Theme.Color.fg3)
                            .frame(width: 22, alignment: .leading)
                        Text(prettyKeyName(step.keyCode))
                            .font(Theme.Font.mono)
                            .foregroundStyle(Theme.Color.fg1)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, 4)
                            .background(Theme.Color.bgRaised)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                        Text("→ then wait \(formatDelay(step.delayAfter))")
                            .font(Theme.Font.bodySmall)
                            .foregroundStyle(Theme.Color.fg2)
                        Spacer()
                        Button("✕") {
                            draftSteps.remove(at: idx)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Color.fg3)
                    }
                }
            }
        }
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if draftSteps.count >= AutoKeysSequence.maxSteps {
                Text("Max 3 steps reached. Remove one to add another.")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg3)
            } else if let captured = pendingKeyCode {
                HStack(spacing: Theme.Spacing.md) {
                    Text("Captured:")
                        .font(Theme.Font.bodySmall)
                        .foregroundStyle(Theme.Color.fg2)
                    Text(prettyKeyName(captured))
                        .font(Theme.Font.mono)
                        .foregroundStyle(Theme.Color.fg1)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, 4)
                        .background(Theme.Color.bgRaised)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    Spacer()
                    Button("Re-capture") {
                        pendingKeyCode = nil
                        capturingKey = true
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Color.fg3)
                }

                HStack(spacing: Theme.Spacing.md) {
                    Text("Delay after:")
                        .font(Theme.Font.bodySmall)
                        .foregroundStyle(Theme.Color.fg2)
                    TextField("Delay", value: $pendingDelaySeconds, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Picker("", selection: $pendingDelayUnit) {
                        ForEach(DelayUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                    Spacer()
                    Button("Add step") {
                        commitStep()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Button(capturingKey ? "Press a key…" : "Capture next key") {
                    pendingKeyCode = nil
                    capturingKey = true
                }
                .buttonStyle(.borderedProminent)
                .background(KeyCaptureRepresentable(capturing: $capturingKey) { code in
                    pendingKeyCode = code
                    capturingKey = false
                })
            }
        }
    }

    private var cyclePreview: some View {
        let estimate = previewEstimate
        let state = CycleBudget.state(for: estimate)
        return HStack(spacing: Theme.Spacing.sm) {
            Circle().fill(stateColor(state)).frame(width: 8, height: 8)
            Text("Estimated cycle: \(formatSeconds(estimate))")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg2)
            Spacer()
            if state == .overCap {
                Text("Over hard cap (\(formatSeconds(CycleBudget.hardCap)))")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.stateDanger)
            } else if state == .warn {
                Text("Approaching cap")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.stateWarn)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { isPresented = false }
            if !draftSteps.isEmpty {
                Button("Clear sequence", role: .destructive) {
                    draftSteps = []
                }
            }
            Spacer()
            Button("Save") {
                save()
                isPresented = false
            }
            .keyboardShortcut(.defaultAction)
            .disabled(saveDisabled)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.Color.bgRaised)
            .frame(height: 1)
    }

    // MARK: - Helpers

    private var saveDisabled: Bool {
        // Save only enabled when the draft is valid AND total cycle is
        // under the cap. Empty sequence is allowed (clears the field).
        if let _ = AutoKeysSequence(steps: draftSteps) {
            return previewEstimate >= CycleBudget.hardCap
        }
        return true
    }

    /// Build a snapshot for the preview: every other configured account
    /// PLUS the in-flight draft for this account.
    private var previewEstimate: TimeInterval {
        let others = AccountStore.shared.accounts
            .filter { $0.userId != account.userId }
            .compactMap { $0.autoKeys }
        let draft = AutoKeysSequence(steps: draftSteps) ?? AutoKeysSequence(steps: [])!
        return CycleBudget.estimate(
            snapshot: others + [draft],
            loopDelay: settings.autoKeysLoopDelay
        )
    }

    private func commitStep() {
        guard let code = pendingKeyCode else { return }
        let seconds = pendingDelaySeconds * pendingDelayUnit.multiplier
        draftSteps.append(AutoKeysStep(keyCode: code, delayAfter: seconds))
        pendingKeyCode = nil
        pendingDelaySeconds = 2
        pendingDelayUnit = .seconds
    }

    private func save() {
        let sequence: AutoKeysSequence?
        if draftSteps.isEmpty {
            sequence = nil
        } else {
            sequence = AutoKeysSequence(steps: draftSteps)
        }
        store.setAutoKeys(userId: account.userId, sequence: sequence)
    }

    private func stateColor(_ s: CycleBudget.State) -> Color {
        switch s {
        case .ok:      return Theme.Color.stateOk
        case .warn:    return Theme.Color.stateWarn
        case .overCap: return Theme.Color.stateDanger
        }
    }

    private func formatDelay(_ seconds: TimeInterval) -> String {
        if seconds >= 60 {
            let mins = seconds / 60
            return String(format: "%.1fm", mins)
        }
        return String(format: "%.1fs", seconds)
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }
}
