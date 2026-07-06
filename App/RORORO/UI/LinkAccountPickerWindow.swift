// LinkAccountPickerWindow.swift
// UI — standalone floating SwiftUI Window scene that asks "which
// account?" for an inbound roblox-player:// URL. Observes
// LinkLaunchCoordinator.shared and renders only when state is
// .choosing. Closes itself when state transitions back to .idle.
//
// Esc / Cmd-W / window-close-button all map to coordinator.cancel().

import SwiftUI

public struct LinkAccountPickerWindow: Scene {

    public static let windowID = "linkAccountPicker"

    public init() {}

    public var body: some Scene {
        Window("Launch as…", id: Self.windowID) {
            LinkAccountPickerWindowContent()
                .frame(width: 380)
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .windowSize) {
                // Suppress the standard "Minimize / Zoom" entries —
                // the picker is a transient utility, not a doc window.
                // Removing this block restores Minimize / Zoom to the
                // Window menu, which is misleading for a picker that
                // auto-dismisses.
            }
        }
    }
}

private struct LinkAccountPickerWindowContent: View {

    // Observation lives on the View, not on the Scene. SwiftUI's Scene
    // lifecycle can re-instantiate the struct without re-establishing
    // an @ObservedObject subscription; View lifecycle is reliable.
    @ObservedObject var coordinator: LinkLaunchCoordinator
    @Environment(\.dismissWindow) private var dismissWindow

    /// Init with the shared coordinator by default. Preview overrides
    /// with a local instance so it can drive the .choosing state
    /// without touching the singleton.
    init(coordinator: LinkLaunchCoordinator = .shared) {
        self.coordinator = coordinator
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .choosing(let pendingURL, let accounts) = coordinator.state {
                header(pendingURL: pendingURL)
                rowList(accounts: accounts)
                footer
            } else {
                // Should not normally render — onChange dismisses the
                // window on .idle — but guard against a one-frame flash.
                Color.clear.frame(height: 1)
            }
        }
        .padding(16)
        .onChange(of: coordinator.state) { _, newState in
            if case .idle = newState {
                dismissWindow(id: LinkAccountPickerWindow.windowID)
            }
        }
        .onDisappear {
            // User clicked the window-close button (red traffic light):
            // the window went away but the coordinator may still hold
            // an in-flight continuation. Treat as Cancel. The state
            // guard makes the intent explicit and avoids redundant work
            // on legitimate dismissals (cancel() / submit() set state
            // to .idle before triggering window close).
            if case .choosing = coordinator.state {
                coordinator.cancel()
            }
        }
    }

    private func header(pendingURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Opening this link with…")
                .font(.caption)
                .foregroundStyle(Theme.Color.fg2)
            Text(pendingURL.absoluteString)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.Color.fg2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func rowList(accounts: [Account]) -> some View {
        VStack(spacing: 6) {
            ForEach(accounts) { account in
                LinkPickerAccountRow(
                    account: account,
                    runningState: runningState(for: account.userId),
                    onTap: { coordinator.submit(userId: account.userId) }
                )
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { coordinator.cancel() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private func runningState(for userId: String) -> LinkPickerAccountRow.RunningState {
        if RunningAccountTracker.shared.pid(for: userId) != nil {
            return .running
        }
        return .idle
        // Note: .active (frontmost) state intentionally omitted in v1 —
        // RunningAccountTracker.pid(for:) reports "we know it's running"
        // but not "it's frontmost right now." Adding frontmost detection
        // is deferred to a future iteration.
    }
}

#Preview("LinkAccountPickerWindow content — 3 accounts") {
    let coord = LinkLaunchCoordinator()
    Task { @MainActor in
        _ = await coord.requestChoice(
            url: URL(string: "roblox-player://1+launchmode+play&placeId=1234567890")!,
            accounts: [
                Account(userId: "1", username: "alt1", displayName: "AltAcct1"),
                Account(userId: "2", username: "alt2", displayName: "AltAcct2"),
                Account(userId: "3", username: "alt3", displayName: "AltAcct3"),
            ]
        )
    }
    return LinkAccountPickerWindowContent(coordinator: coord)
        .frame(width: 380)
        .padding(16)
}
