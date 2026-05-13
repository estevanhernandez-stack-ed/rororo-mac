// KeychainBootstrapPromptSheet.swift
// UI — one-time onboarding sheet that frames the macOS Keychain prompt
// the user is about to see. Without this framing, the prompt looks
// like an unrelated app asking for credentials. With it, the user
// knows RORORO is setting up its own private keychain so Roblox can
// launch additional accounts without a password prompt each time.
//
// State machine: .waiting (user hasn't clicked Continue yet) →
// .running (bootstrap in flight; macOS prompt may be visible) →
// .done (caller dismisses) | .failed(message) (show error + Retry).
//
// Manual smoke only — SwiftUI render tests aren't worth their weight
// for a single informational sheet. To trigger manually:
//   defaults delete com.626labs.rororo-mac RororoKeychainBootstrapVersion
//   security delete-keychain ~/Library/Keychains/RORORO.keychain
// Then launch RORORO from Xcode.

import SwiftUI

public struct KeychainBootstrapPromptSheet: View {

    public enum Phase: Equatable {
        case waiting
        case running
        case failed(String)
        case done
    }

    @State private var phase: Phase = .waiting
    let onDone: () -> Void

    public init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("One-time setup")
                .font(.title2).bold()

            Text("""
            RORORO needs your permission to create a private macOS keychain. \
            This lets you launch additional Roblox accounts without macOS \
            asking for your password every time.

            You'll see one macOS prompt asking to modify your keychain list. \
            Click Always Allow. This is a one-time step — you won't see it \
            again on this machine.
            """)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.primary)

            Divider()

            switch phase {
            case .waiting:
                HStack {
                    Button("Not now") { onDone() }
                    Spacer()
                    Button("Continue") { run() }
                        .keyboardShortcut(.defaultAction)
                }
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for macOS prompt — enter your password, then click Always Allow.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Setup failed")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Skip") { onDone() }
                        Spacer()
                        Button("Retry") { run() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            case .done:
                EmptyView()
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func run() {
        phase = .running
        Task.detached(priority: .userInitiated) {
            do {
                try await RororoKeychainBootstrap.ensureIfNeeded()
                await MainActor.run {
                    phase = .done
                    onDone()
                }
            } catch {
                await MainActor.run {
                    phase = .failed("\(error)")
                }
            }
        }
    }
}
