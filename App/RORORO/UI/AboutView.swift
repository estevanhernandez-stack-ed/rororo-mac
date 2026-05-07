// AboutView.swift
// Version + license + provenance. Provenance line credits MultiBloxy
// (Windows mutex technique) and Insadem (macOS sem_unlink technique).
// Every release ships with this surface so the credit stays load-bearing.

import SwiftUI

struct AboutView: View {
    @Binding var isPresented: Bool

    // Easter egg ported from RORORO Windows: tap the version number 6 or
    // 7 times (chosen randomly per sheet open so you can't know the exact
    // count) to reveal the Koii 4 eva tag. Resets when the sheet closes
    // and re-opens.
    @State private var versionTapCount = 0
    @State private var koiiThreshold = Int.random(in: 6...7)
    @State private var koiiRevealed = false
    @State private var koiiPulse: CGFloat = 1.0

    private var version: String {
        let bundle = Bundle.main
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Text("RORORO")
                .font(Theme.Font.display)
                .foregroundStyle(Theme.Color.fg1)

            Text("Mac-native multi-Roblox launcher")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg2)

            Text(version)
                .font(Theme.Font.mono)
                .foregroundStyle(Theme.Color.fg3)
                .contentShape(Rectangle())
                .onTapGesture {
                    handleVersionTap()
                }

            if koiiRevealed {
                koiiTag
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("What's new in v0.2".uppercased())
                    .font(Theme.Font.monoMicro)
                    .foregroundStyle(Theme.Color.fg3)
                    .tracking(1.4)
                Text("Saved favorite games + private servers, picker dropdown on every Launch As, share-token URL resolver, branded DMG + app icon. Click Games in the toolbar.")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.Spacing.xs)

            Spacer()

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Provenance".uppercased())
                    .font(Theme.Font.monoMicro)
                    .foregroundStyle(Theme.Color.fg3)
                    .tracking(1.4)
                Text("Multi-instance technique: MultiBloxy (Windows mutex) and Insadem multi-roblox-macos (macOS POSIX sem_unlink). Reimplemented in Swift; no code copied.")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("MIT License — © 2026 626 Labs LLC")
                .font(Theme.Font.monoMicro)
                .foregroundStyle(Theme.Color.fg3)

            Button("Close") { isPresented = false }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.bordered)
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 420, height: 420)
        .background(Theme.Color.bgPage)
        .onDisappear {
            // Reset so the next opening starts fresh — and re-rolls the
            // 6-or-7 threshold so you can't memorize it.
            versionTapCount = 0
            koiiRevealed = false
            koiiThreshold = Int.random(in: 6...7)
            koiiPulse = 1.0
        }
    }

    private func handleVersionTap() {
        guard !koiiRevealed else { return }
        versionTapCount += 1
        if versionTapCount >= koiiThreshold {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) {
                koiiRevealed = true
            }
            // Gentle pulse forever after reveal.
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                koiiPulse = 1.06
            }
        }
    }

    /// Brand-gradient text on a brand-gradient capsule outline with a
    /// dual cyan + magenta glow. Pulses gently after reveal. Faithful
    /// port of the RORORO Windows easter egg with macOS-shaped polish.
    private var koiiTag: some View {
        Text("Koii 4 eva 💖")
            .font(Theme.Font.heading2)
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        Theme.Color.brandCyan,
                        Theme.Color.brandMagenta,
                        Theme.Color.brandCyan,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Theme.Color.brandCyan, Theme.Color.brandMagenta],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 2
                    )
            )
            .shadow(color: Theme.Color.brandMagenta.opacity(0.55), radius: 12)
            .shadow(color: Theme.Color.brandCyan.opacity(0.55), radius: 8)
            .scaleEffect(koiiPulse)
    }
}
