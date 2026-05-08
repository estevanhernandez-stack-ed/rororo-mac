// AutoKeysPermissions.swift
// Domain — TCC consent helpers for the auto-keys cycler (Slope C, ADR
// 0004 Decisions 8 + 9). Two privacy buckets matter:
//
//   - Accessibility (`AXIsProcessTrusted`) — needed to post `CGEvent`
//     keystrokes via the cycler's `KeyEventPoster`.
//   - Input Monitoring (`IOHIDCheckAccess(.listenEvent)`) — needed for
//     the safety monitor's global `NSEvent` listeners. Without it the
//     engagement detector + kill-key recognizer silently no-op.
//
// macOS 14+ keeps these in separate panes of System Settings. The
// recorder + toolbar surface deep-links to each pane so the user
// can grant both without navigating Settings manually.

import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

public enum AutoKeysPermissions {

    public enum Status: Equatable, Sendable {
        case granted
        case denied
        case notDetermined
    }

    /// True iff the app is in System Settings → Privacy & Security →
    /// Accessibility AND has the toggle on. The bare check; no prompt.
    public static func accessibilityStatus() -> Status {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Status of the global-event-listener bucket (Input Monitoring).
    /// `IOHIDCheckAccess` distinguishes denied vs not-yet-asked, so the
    /// recorder UI can show "request" vs "open settings to grant" with
    /// the right copy.
    public static func inputMonitoringStatus() -> Status {
        let raw = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch raw {
        case kIOHIDAccessTypeGranted:    return .granted
        case kIOHIDAccessTypeDenied:     return .denied
        case kIOHIDAccessTypeUnknown:    return .notDetermined
        default:                         return .notDetermined
        }
    }

    /// Trigger the system Input Monitoring prompt. macOS shows the
    /// native dialog the first time; subsequent calls are no-ops if
    /// already granted, and silently fail if the user denied.
    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Open System Settings directly to the Accessibility pane. The
    /// user-facing copy in the recorder uses this when status is
    /// `.denied` (already shown — settings is the way back).
    public static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open System Settings to the Input Monitoring pane.
    public static func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
