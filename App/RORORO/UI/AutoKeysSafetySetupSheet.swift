// AutoKeysSafetySetupSheet.swift
// One-time global setup for the cycler's safety controls (Slope C
// wave 3b, ADR 0004 Decision 9). The user picks a kill key + the
// gesture (hold-1s OR double-tap), and we surface the dual-TCC
// posture (Accessibility + Input Monitoring) so the prompts aren't
// surprising at Play time. Re-runnable from Settings to change either.

import AppKit
import CoreGraphics
import SwiftUI

struct AutoKeysSafetySetupSheet: View {

    @Binding var isPresented: Bool

    @State private var capturedKeyCode: CGKeyCode = AutoKeysSafetyConfig.defaultKillKeyCode
    @State private var capturing: Bool = false
    @State private var gesture: KillGesture = .defaultHold
    @State private var resumeGrace: TimeInterval = 5

    @State private var accessibility: AutoKeysPermissions.Status = .notDetermined
    @State private var inputMonitoring: AutoKeysPermissions.Status = .notDetermined

    private let settings = LaunchSettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            header

            divider

            killKeySection

            divider

            gestureSection

            divider

            permissionsSection

            Spacer(minLength: 0)

            footer
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 520, height: 620)
        .background(Theme.Color.bgPage)
        .onAppear {
            // Hydrate from existing config on re-entry.
            let existing = settings.autoKeysSafety
            capturedKeyCode = existing.killKeyCode
            gesture = existing.gesture
            resumeGrace = existing.resumeGrace
            refreshPermissions()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Auto-keys safety setup")
                .font(Theme.Font.heading2)
                .foregroundStyle(Theme.Color.fg1)
            Text("Pick how to stop the cycler if it goes off the rails. Required before Play.")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg2)
        }
    }

    private var killKeySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Kill key")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg2)
                .textCase(.uppercase)
                .tracking(0.7)

            HStack(spacing: Theme.Spacing.md) {
                Text(prettyKeyName(capturedKeyCode))
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.Color.fg1)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(Theme.Color.bgRaised)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))

                Button(capturing ? "Press a key…" : "Change") {
                    capturing.toggle()
                }
                .disabled(capturing && false)
                .keyboardShortcut(.defaultAction)
                .background(KeyCaptureRepresentable(capturing: $capturing) { code in
                    capturedKeyCode = code
                    capturing = false
                })
            }

            Text("Pick a key NOT bound in your Roblox keybinds (function keys F13–F19 are safest). Pressing it twice / holding it stops the cycler from anywhere on your Mac.")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var gestureSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Stop gesture")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg2)
                .textCase(.uppercase)
                .tracking(0.7)

            HStack(spacing: Theme.Spacing.sm) {
                gestureChip(
                    label: "Hold for 1s",
                    selected: isHold,
                    onTap: { gesture = .holdFor(seconds: 1.0) }
                )
                gestureChip(
                    label: "Double-tap",
                    selected: !isHold,
                    onTap: { gesture = .doubleTap(withinSeconds: 0.6) }
                )
            }

            Text(isHold
                 ? "Press and hold for one full second. Lower false-positive risk."
                 : "Two presses inside 600ms. Faster on muscle memory.")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg3)
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Permissions needed")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg2)
                .textCase(.uppercase)
                .tracking(0.7)

            permissionRow(
                title: "Accessibility",
                detail: "Lets RORORO post keystrokes into your Roblox windows.",
                status: accessibility,
                action: AutoKeysPermissions.openAccessibilitySettings
            )
            permissionRow(
                title: "Input Monitoring",
                detail: "Lets RORORO see your kill-key presses + pause when you move the mouse.",
                status: inputMonitoring,
                action: {
                    AutoKeysPermissions.requestInputMonitoring()
                    AutoKeysPermissions.openInputMonitoringSettings()
                }
            )
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { isPresented = false }
            Spacer()
            Button("Save") {
                save()
                isPresented = false
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.Color.bgRaised)
            .frame(height: 1)
    }

    // MARK: - Helpers

    private var isHold: Bool {
        if case .holdFor = gesture { return true }
        return false
    }

    private func gestureChip(label: String, selected: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            Text(label)
                .font(Theme.Font.bodySmall)
                .foregroundStyle(selected ? Color.white : Theme.Color.fg2)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.pill)
                        .fill(selected ? Theme.Color.brandCyan : Theme.Color.bgRaised)
                )
        }
        .buttonStyle(.plain)
    }

    private func permissionRow(
        title: String,
        detail: String,
        status: AutoKeysPermissions.Status,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Circle()
                .fill(status == .granted ? Theme.Color.stateOk : Theme.Color.stateWarn)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.body).foregroundStyle(Theme.Color.fg1)
                Text(detail)
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if status != .granted {
                Button("Open") { action() }
                    .font(Theme.Font.bodySmall)
            } else {
                Text("Granted")
                    .font(Theme.Font.monoMicro)
                    .foregroundStyle(Theme.Color.stateOk)
            }
        }
    }

    private func refreshPermissions() {
        accessibility = AutoKeysPermissions.accessibilityStatus()
        inputMonitoring = AutoKeysPermissions.inputMonitoringStatus()
    }

    private func save() {
        settings.setAutoKeysSafety(
            AutoKeysSafetyConfig(
                killKeyCode: capturedKeyCode,
                gesture: gesture,
                resumeGrace: resumeGrace
            )
        )
        // Flip the "user has explicitly configured safety" flag so the
        // toolbar's Play button stops gating on the setup sheet from
        // here on. Re-runnable from Settings to change either field.
        UserDefaults.standard.set(true, forKey: "rororo.autoKeys.safety.configured")
    }
}

/// AppKit shim for one-shot keyDown capture while the sheet is frontmost.
/// SwiftUI's `.onKeyPress` is iOS 17+/macOS 14+ but doesn't capture
/// modifier-free function-key presses cleanly — NSEvent local monitor
/// is the load-bearing path. Lifted from the recorder sheet pattern.
struct KeyCaptureRepresentable: NSViewRepresentable {

    @Binding var capturing: Bool
    let onKey: (CGKeyCode) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if capturing && context.coordinator.monitor == nil {
            context.coordinator.install { code in
                onKey(code)
            }
        } else if !capturing && context.coordinator.monitor != nil {
            context.coordinator.uninstall()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var monitor: Any?
        func install(handler: @escaping (CGKeyCode) -> Void) {
            uninstall()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handler(CGKeyCode(event.keyCode))
                return nil // swallow — sheet's text fields shouldn't see it
            }
        }
        func uninstall() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }
    }
}

/// Map a CGKeyCode → human-readable name for the recorder UI. Covers
/// the subset most users will encounter (function row, common letters,
/// space, return, modifiers); falls back to "key #N" for the rest.
/// Layout-independent — keyCodes are physical-position regardless of
/// the user's active keyboard layout.
func prettyKeyName(_ code: CGKeyCode) -> String {
    switch code {
    case 49: return "Space"
    case 36: return "Return"
    case 53: return "Escape"
    case 51: return "Delete"
    case 48: return "Tab"
    case 122: return "F1"
    case 120: return "F2"
    case 99:  return "F3"
    case 118: return "F4"
    case 96:  return "F5"
    case 97:  return "F6"
    case 98:  return "F7"
    case 100: return "F8"
    case 101: return "F9"
    case 109: return "F10"
    case 103: return "F11"
    case 111: return "F12"
    case 105: return "F13"
    case 107: return "F14"
    case 113: return "F15"
    case 106: return "F16"
    case 64:  return "F17"
    case 79:  return "F18"
    case 80:  return "F19"
    case 0:   return "A"
    case 1:   return "S"
    case 2:   return "D"
    case 13:  return "W"
    case 12:  return "Q"
    case 14:  return "E"
    case 15:  return "R"
    case 17:  return "T"
    default:  return "key #\(code)"
    }
}
