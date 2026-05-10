// MouseEventPoster.swift
// Domain — DI seam over `CGEvent` mouse posting for the action-stream
// player (Wave D-3.1). Mirrors `KeyEventPoster`: a protocol so the
// cycler is testable without grabbing the system event tap, plus a
// production conformance that calls `CGEvent.post`.
//
// All three event kinds self-tag with `AutoKeysCyclerSourceTag`
// (ADR 0007 Decision 5 — mouse posting piggybacks on the same
// Accessibility TCC consent the keyboard path already holds, and self-
// tagging keeps the safety monitor from pausing the cycler on its own
// mouse events).
//
// Coords here are absolute screen positions in CGEvent's top-left
// origin coordinate system. The player is responsible for translating
// window-relative `AutoKeysAction.rel` values through
// `WindowRectTracker` before calling these methods — this layer is
// dumb and just posts what it's given.

import CoreGraphics
import Foundation

public protocol MouseEventPoster: Sendable {
    /// Post a mouse-moved event at an absolute screen position.
    func postMove(to position: CGPoint) async
    /// Post a button-down event at an absolute screen position.
    func postDown(button: MouseButton, at position: CGPoint) async
    /// Post a button-up event at an absolute screen position.
    func postUp(button: MouseButton, at position: CGPoint) async
}

public struct CGEventMouseEventPoster: MouseEventPoster {

    public init() {}

    public func postMove(to position: CGPoint) async {
        post(type: .mouseMoved, button: nil, position: position)
    }

    public func postDown(button: MouseButton, at position: CGPoint) async {
        let type: CGEventType = (button == .left) ? .leftMouseDown : .rightMouseDown
        post(type: type, button: button, position: position)
    }

    public func postUp(button: MouseButton, at position: CGPoint) async {
        let type: CGEventType = (button == .left) ? .leftMouseUp : .rightMouseUp
        post(type: type, button: button, position: position)
    }

    private func post(type: CGEventType, button: MouseButton?, position: CGPoint) {
        let mouseButton: CGMouseButton = (button == .right) ? .right : .left
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: position,
            mouseButton: mouseButton
        ) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: AutoKeysCyclerSourceTag)
        event.post(tap: .cghidEventTap)
    }
}
