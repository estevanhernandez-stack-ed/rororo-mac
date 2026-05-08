// KeyEventPoster.swift
// Domain — DI seam over `CGEvent` keyboard posting for the auto-keys
// cycler (Slope C). The protocol exists so `AutoKeysCycler` is testable
// without grabbing the system event tap; production conformance is the
// real `CGEvent.post` call.
//
// Posting requires Accessibility (TCC). The cycler checks
// `AXIsProcessTrusted()` before starting and surfaces a banner if false;
// this type does not.

import CoreGraphics
import Foundation

public protocol KeyEventPoster: Sendable {
    /// Post a complete press: keyDown, ~20ms, keyUp.
    func post(keyCode: CGKeyCode) async
}

public struct CGEventKeyEventPoster: KeyEventPoster {

    /// Gap between the keyDown and the keyUp. Roblox's input layer wants
    /// to see a discrete press, not a held key — 20ms is well above the
    /// per-frame sample interval and still below human perception.
    public let pressDuration: TimeInterval

    public init(pressDuration: TimeInterval = 0.020) {
        self.pressDuration = pressDuration
    }

    public func post(keyCode: CGKeyCode) async {
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
            down.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(nanoseconds: UInt64(pressDuration * 1_000_000_000))
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
            up.post(tap: .cghidEventTap)
        }
    }
}
