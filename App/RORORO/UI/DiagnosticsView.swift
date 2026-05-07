// DiagnosticsView.swift
// Read-only inspector for "is the system happy?" — surfaces the most
// recent launch error, whether /Applications/Roblox.app is present, and
// the canonical Roblox singleton-semaphore name (so a future Roblox
// rename is visible from the UI without grepping the codebase).

import SwiftUI

struct DiagnosticsView: View {
    @Binding var isPresented: Bool

    private let robloxInstalled = FileManager.default.fileExists(atPath: RobloxAppCopier.robloxAppPath)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack {
                Text("Diagnostics")
                    .font(Theme.Font.heading1)
                    .foregroundStyle(Theme.Color.fg1)
                Spacer()
                Button("Close") { isPresented = false }
            }

            section("Roblox Install") {
                row("Path", value: RobloxAppCopier.robloxAppPath)
                row("Found", value: robloxInstalled ? "Yes" : "No",
                    color: robloxInstalled ? Theme.Color.stateOk : Theme.Color.stateDanger)
            }

            section("Multi-instance") {
                let state = MultiInstanceState.shared
                row("Enabled", value: state.enabled ? "Yes" : "No",
                    color: state.enabled ? Theme.Color.stateOk : Theme.Color.fg3)
                row("Successful launches this session", value: "\(state.instanceCount)")
                row("URL scheme handler", value: URLSchemeHandler.shared.isClaimed ? "Claimed by RORORO" : "Not claimed")
                if let error = state.lastError {
                    Text("Last error")
                        .font(Theme.Font.monoMicro)
                        .foregroundStyle(Theme.Color.fg3)
                    Text(error)
                        .font(Theme.Font.mono)
                        .foregroundStyle(Theme.Color.stateDanger)
                        .padding(Theme.Spacing.sm)
                        .background(Theme.Color.bgRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }
            }

            section("Roblox Internals") {
                row("Singleton semaphore", value: SemaphoreBreaker.robloxSingletonSemaphoreName)
                Text("If a future Roblox client renames this semaphore, multi-instance launches will silently start failing. Update SemaphoreBreaker.robloxSingletonSemaphoreName.")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg3)
            }

            Spacer()
        }
        .padding(Theme.Spacing.lg)
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

    private func row(_ label: String, value: String, color: SwiftUI.Color = Theme.Color.fg1) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg2)
                .frame(width: 220, alignment: .leading)
            Text(value)
                .font(Theme.Font.mono)
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
    }
}
