// RecorderEventSource.swift
// Domain — input-event source for `ActionStreamRecorder` (Wave D-3.3 /
// ADR 0007). Separate from the safety monitor's `EventTapping` because:
//
//   - The recorder needs absolute mouse positions + the down/up split
//     (mouseDown, mouseUp); the safety monitor only sees `.mouseMoved`
//     for engagement gating.
//   - Expanding `TappedEvent.Kind` with new cases + a `position` field
//     would touch the safety monitor's classification path and its
//     existing test fakes. The recorder's contract is narrow enough to
//     deserve its own surface.
//
// Production wires `NSEventRecorderEventSource` — a thin wrapper over
// `NSEvent` global + local monitors with the recorder's full mask. The
// position field is read from `event.cgEvent?.location` (top-left
// origin, matching `WindowRectTracker`'s AX rect convention) so the
// recorder never sees mixed coord systems.

import AppKit
import CoreGraphics
import Foundation

public struct RecorderEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case keyDown(CGKeyCode)
        case keyUp(CGKeyCode)
        case mouseMoved
        case mouseDown(MouseButton)
        case mouseUp(MouseButton)
    }
    public let kind: Kind
    /// Top-left-origin screen coords. nil for keyboard events.
    public let position: CGPoint?
    public let modifiers: UInt
    /// True iff the event carries the cycler's `AutoKeysCyclerSourceTag`.
    /// The recorder ignores self-tagged events so a user mid-record
    /// can't accidentally capture the cycler's own posted events from
    /// a parallel run.
    public let isSelfTagged: Bool

    public init(
        kind: Kind,
        position: CGPoint? = nil,
        modifiers: UInt = 0,
        isSelfTagged: Bool = false
    ) {
        self.kind = kind
        self.position = position
        self.modifiers = modifiers
        self.isSelfTagged = isSelfTagged
    }
}

public protocol RecorderEventSource: Sendable {
    /// Begin capturing events. Returns a stream the recorder walks in a
    /// long-lived task; stopping cancels the underlying monitors.
    func start() -> AsyncStream<RecorderEvent>
    /// Tear down the underlying monitors. Idempotent.
    func stop()
}

/// Production conformance — registers NSEvent global + local monitors
/// for the full recorder mask. Self-tag detection matches
/// `NSEventTapping`'s pattern.
public final class NSEventRecorderEventSource: RecorderEventSource, @unchecked Sendable {

    private let lock = NSLock()
    private var globalMonitors: [Any] = []
    private var localMonitors: [Any] = []
    private var continuation: AsyncStream<RecorderEvent>.Continuation?

    public init() {}

    public func start() -> AsyncStream<RecorderEvent> {
        AsyncStream { [weak self] continuation in
            guard let self else { continuation.finish(); return }
            self.lock.lock()
            self.continuation = continuation
            self.installMonitorsLocked()
            self.lock.unlock()

            continuation.onTermination = { @Sendable [weak self] _ in
                self?.stop()
            }
        }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        for m in globalMonitors { NSEvent.removeMonitor(m) }
        for m in localMonitors  { NSEvent.removeMonitor(m) }
        globalMonitors.removeAll()
        localMonitors.removeAll()
        continuation?.finish()
        continuation = nil
    }

    private func installMonitorsLocked() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .leftMouseDragged, .rightMouseDragged,
            .keyDown, .keyUp,
        ]
        let globalHandler: (NSEvent) -> Void = { [weak self] event in
            self?.deliver(event: event)
        }
        let localHandler: (NSEvent) -> NSEvent? = { [weak self] event in
            self?.deliver(event: event)
            return event
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: globalHandler) {
            globalMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: localHandler) {
            localMonitors.append(l)
        }
    }

    private func deliver(event: NSEvent) {
        guard let kind = Self.classify(event) else { return }
        let position = event.cgEvent?.location
        let modifiers = event.modifierFlags.rawValue & KillKeyCombo.relevantModifierMask
        let isSelfTagged = Self.isSelfTagged(event)
        let rec = RecorderEvent(
            kind: kind,
            position: position,
            modifiers: modifiers,
            isSelfTagged: isSelfTagged
        )
        lock.lock()
        let cont = continuation
        lock.unlock()
        cont?.yield(rec)
    }

    private static func classify(_ event: NSEvent) -> RecorderEvent.Kind? {
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            // Drags are mouseMoves with a button held — the down/up
            // events fire separately. Collapse them to mouseMoved so
            // the player's translation path is uniform.
            return .mouseMoved
        case .leftMouseDown:
            return .mouseDown(.left)
        case .leftMouseUp:
            return .mouseUp(.left)
        case .rightMouseDown:
            return .mouseDown(.right)
        case .rightMouseUp:
            return .mouseUp(.right)
        case .keyDown:
            return .keyDown(CGKeyCode(event.keyCode))
        case .keyUp:
            return .keyUp(CGKeyCode(event.keyCode))
        default:
            return nil
        }
    }

    private static func isSelfTagged(_ event: NSEvent) -> Bool {
        guard let cg = event.cgEvent else { return false }
        return cg.getIntegerValueField(.eventSourceUserData) == AutoKeysCyclerSourceTag
    }
}
