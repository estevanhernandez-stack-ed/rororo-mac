// AutoKeysAction.swift
// Domain — the 5-case action enum that replaces `AutoKeysStep` as the
// substrate for full-fidelity record-and-replay (ADR 0007 Decision 1).
//
// Why split keyDown / keyUp into separate cases instead of the
// `AutoKeysStep.delayAfter` shape from ADR 0004: the original step model
// always fired the down + up back-to-back inside `KeyEventPoster.post`,
// which made it impossible to record a held key spanning other actions
// (movement-while-clicking, charged attacks). The action stream models
// each transition as its own event so overlap survives.
//
// `dt` is the delay *before* firing this action — time since the prior
// action — measured by `ActionStreamRecorder` via `CACurrentMediaTime()`
// (ADR 0007 Decision 8) and replayed by `ActionStreamPlayer` as a sleep
// before the underlying CGEvent post.
//
// All mouse coords are stored window-relative (top-left origin) per
// ADR 0007 Decision 2. The player translates to absolute screen coords
// via `WindowRectTracker` at fire time so window moves survive.
//
// Codable shape is tagged + flat (`{"kind":"keyDown","keyCode":49,
// "modifiers":0,"dt":0.123}`) instead of relying on Swift's synthesized
// enum-with-associated-values format. The synthesized format is
// `{"keyDown":{"keyCode":...}}` which is harder to read in a debugger
// and changes shape when a case is added or removed; the manual shape
// is explicit and forward-stable.

import CoreGraphics
import Foundation

public enum MouseButton: String, Codable, Equatable, Sendable {
    case left
    case right
}

public enum AutoKeysAction: Equatable, Sendable {
    case keyDown(keyCode: CGKeyCode, modifiers: UInt, dt: TimeInterval)
    case keyUp(keyCode: CGKeyCode, modifiers: UInt, dt: TimeInterval)
    case mouseMove(rel: CGPoint, dt: TimeInterval)
    case mouseDown(MouseButton, rel: CGPoint, dt: TimeInterval)
    case mouseUp(MouseButton, rel: CGPoint, dt: TimeInterval)

    public var dt: TimeInterval {
        switch self {
        case let .keyDown(_, _, dt),
             let .keyUp(_, _, dt):
            return dt
        case let .mouseMove(_, dt):
            return dt
        case let .mouseDown(_, _, dt),
             let .mouseUp(_, _, dt):
            return dt
        }
    }
}

// MARK: - Codable

extension AutoKeysAction: Codable {

    private enum Kind: String, Codable {
        case keyDown
        case keyUp
        case mouseMove
        case mouseDown
        case mouseUp
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case keyCode
        case modifiers
        case button
        case relX
        case relY
        case dt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        let dt = try c.decode(TimeInterval.self, forKey: .dt)
        switch kind {
        case .keyDown:
            let keyCode = try c.decode(CGKeyCode.self, forKey: .keyCode)
            let modifiers = try c.decode(UInt.self, forKey: .modifiers)
            self = .keyDown(keyCode: keyCode, modifiers: modifiers, dt: dt)
        case .keyUp:
            let keyCode = try c.decode(CGKeyCode.self, forKey: .keyCode)
            let modifiers = try c.decode(UInt.self, forKey: .modifiers)
            self = .keyUp(keyCode: keyCode, modifiers: modifiers, dt: dt)
        case .mouseMove:
            let x = try c.decode(CGFloat.self, forKey: .relX)
            let y = try c.decode(CGFloat.self, forKey: .relY)
            self = .mouseMove(rel: CGPoint(x: x, y: y), dt: dt)
        case .mouseDown:
            let button = try c.decode(MouseButton.self, forKey: .button)
            let x = try c.decode(CGFloat.self, forKey: .relX)
            let y = try c.decode(CGFloat.self, forKey: .relY)
            self = .mouseDown(button, rel: CGPoint(x: x, y: y), dt: dt)
        case .mouseUp:
            let button = try c.decode(MouseButton.self, forKey: .button)
            let x = try c.decode(CGFloat.self, forKey: .relX)
            let y = try c.decode(CGFloat.self, forKey: .relY)
            self = .mouseUp(button, rel: CGPoint(x: x, y: y), dt: dt)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .keyDown(keyCode, modifiers, dt):
            try c.encode(Kind.keyDown, forKey: .kind)
            try c.encode(keyCode, forKey: .keyCode)
            try c.encode(modifiers, forKey: .modifiers)
            try c.encode(dt, forKey: .dt)
        case let .keyUp(keyCode, modifiers, dt):
            try c.encode(Kind.keyUp, forKey: .kind)
            try c.encode(keyCode, forKey: .keyCode)
            try c.encode(modifiers, forKey: .modifiers)
            try c.encode(dt, forKey: .dt)
        case let .mouseMove(rel, dt):
            try c.encode(Kind.mouseMove, forKey: .kind)
            try c.encode(rel.x, forKey: .relX)
            try c.encode(rel.y, forKey: .relY)
            try c.encode(dt, forKey: .dt)
        case let .mouseDown(button, rel, dt):
            try c.encode(Kind.mouseDown, forKey: .kind)
            try c.encode(button, forKey: .button)
            try c.encode(rel.x, forKey: .relX)
            try c.encode(rel.y, forKey: .relY)
            try c.encode(dt, forKey: .dt)
        case let .mouseUp(button, rel, dt):
            try c.encode(Kind.mouseUp, forKey: .kind)
            try c.encode(button, forKey: .button)
            try c.encode(rel.x, forKey: .relX)
            try c.encode(rel.y, forKey: .relY)
            try c.encode(dt, forKey: .dt)
        }
    }
}
