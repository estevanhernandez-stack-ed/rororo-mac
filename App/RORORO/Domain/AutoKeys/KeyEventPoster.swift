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
    /// Post a complete press: keyDown, ~20ms, keyUp. Used by the legacy
    /// step-list path (ADR 0004) where every step is a discrete press.
    func post(keyCode: CGKeyCode) async
    /// Post a standalone keyDown with the given modifier flags. Used by
    /// `ActionStreamPlayer` (ADR 0007) where down/up are separate
    /// actions in the recorded stream — overlap is the whole point.
    func postDown(keyCode: CGKeyCode, modifiers: UInt) async
    /// Post a standalone keyUp paired with a prior `postDown`. The
    /// player guarantees pairing on cancellation cleanup.
    func postUp(keyCode: CGKeyCode, modifiers: UInt) async
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
        // Tag both the down and up event with the cycler's source tag so
        // the safety monitor can ignore them — otherwise the engagement
        // detector would pause the cycler on every keystroke it fires
        // (ADR 0004 Decision 9).
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
            down.setIntegerValueField(.eventSourceUserData, value: AutoKeysCyclerSourceTag)
            down.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(nanoseconds: UInt64(pressDuration * 1_000_000_000))
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
            up.setIntegerValueField(.eventSourceUserData, value: AutoKeysCyclerSourceTag)
            up.post(tap: .cghidEventTap)
        }
    }

    public func postDown(keyCode: CGKeyCode, modifiers: UInt) async {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
        if modifiers != 0 {
            down.flags = CGEventFlags(rawValue: UInt64(modifiers))
        }
        down.setIntegerValueField(.eventSourceUserData, value: AutoKeysCyclerSourceTag)
        down.post(tap: .cghidEventTap)
    }

    public func postUp(keyCode: CGKeyCode, modifiers: UInt) async {
        guard let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        if modifiers != 0 {
            up.flags = CGEventFlags(rawValue: UInt64(modifiers))
        }
        up.setIntegerValueField(.eventSourceUserData, value: AutoKeysCyclerSourceTag)
        up.post(tap: .cghidEventTap)
    }
}
