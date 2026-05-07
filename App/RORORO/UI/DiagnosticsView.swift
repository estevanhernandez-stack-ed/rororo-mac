// DiagnosticsView.swift
// Read-only inspector for "is the system happy?" — surfaces the most
// recent launch error, whether /Applications/Roblox.app is present, and
// the canonical Roblox singleton-semaphore name (so a future Roblox
// rename is visible from the UI without grepping the codebase).

import AppKit
import SwiftUI

struct DiagnosticsView: View {
    @Binding var isPresented: Bool

    private let robloxInstalled = FileManager.default.fileExists(atPath: RobloxAppCopier.robloxAppPath)
    @State private var copiedFlash = false
    @State private var bundleSavingError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack {
                Text("Diagnostics")
                    .font(Theme.Font.heading1)
                    .foregroundStyle(Theme.Color.fg1)
                Spacer()
                Button(copiedFlash ? "Copied!" : "Copy") { copyAll() }
                    .buttonStyle(.bordered)
                    .tint(Theme.Color.productTeal)
                    .help("Copy a structured snapshot of state to the clipboard.")
                Button("Save bundle…") { saveBundle() }
                    .buttonStyle(.bordered)
                    .tint(Theme.Color.productTeal)
                    .help("Save a .zip with logs + (cookie-free) state for bug reports.")
                Button("Close") { isPresented = false }
            }
            .alert("Couldn't save bundle", isPresented: Binding(
                get: { bundleSavingError != nil },
                set: { _ in bundleSavingError = nil }
            )) {
                Button("OK") { bundleSavingError = nil }
            } message: {
                Text(bundleSavingError ?? "")
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
                    ScrollView(.vertical) {
                        Text(error)
                            .font(Theme.Font.mono)
                            .foregroundStyle(Theme.Color.stateDanger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 160)
                    .padding(Theme.Spacing.sm)
                    .background(Theme.Color.bgRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }
            }

            section("Roblox Internals") {
                let store = RobloxCompatStore.shared
                row("Effective semaphore", value: store.currentSemaphoreName())
                row("Compat feed", value: store.freshness())
                if let err = store.lastFetchError {
                    row("Compat fetch error", value: err, color: Theme.Color.stateWarn)
                }
                Text("Semaphore name comes from the remote roblox-compat.json feed (5-min TTL). If the feed is unreachable, the app falls back to its built-in default. Surface this to verify a future Roblox rename has been picked up.")
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

    private func saveBundle() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "RORORO-diagnostics-\(timestamp).zip"
        panel.canCreateDirectories = true
        panel.title = "Save diagnostics bundle"
        panel.message = "A .zip with logs + non-secret state. Cookies stay in Keychain; private-server codes are redacted."

        panel.begin { result in
            guard result == .OK, let dest = panel.url else { return }
            Task.detached(priority: .userInitiated) {
                do {
                    try await DiagnosticsBundle.writeBundle(to: dest)
                } catch {
                    await MainActor.run {
                        bundleSavingError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func copyAll() {
        let state = MultiInstanceState.shared
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        var lines: [String] = []
        lines.append("=== RORORO Diagnostics ===")
        lines.append("Version: \(version) (\(build))")
        lines.append("Roblox installed: \(robloxInstalled ? "Yes" : "No") at \(RobloxAppCopier.robloxAppPath)")
        lines.append("Multi-instance enabled: \(state.enabled)")
        lines.append("Successful launches this session: \(state.instanceCount)")
        lines.append("URL scheme handler claimed: \(URLSchemeHandler.shared.isClaimed)")
        lines.append("Singleton semaphore: \(SemaphoreBreaker.robloxSingletonSemaphoreName)")
        lines.append("Last error:")
        lines.append(state.lastError ?? "(none)")
        let body = lines.joined(separator: "\n")

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(body, forType: .string)

        copiedFlash = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedFlash = false
        }
    }
}
