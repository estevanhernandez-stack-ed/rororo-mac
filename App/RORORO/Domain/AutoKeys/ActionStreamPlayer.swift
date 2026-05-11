// ActionStreamPlayer.swift
// Domain — the replay engine for `AutoKeysSequence.Variant.stream`
// payloads (ADR 0007 Decision 1). Consumes `[AutoKeysAction]`, sleeps
// per-action `dt`, translates window-relative mouse coords to absolute
// screen coords via `WindowRectTracker`, and posts through the same
// DI seams the cycler already uses.
//
// Outcomes (one per `play(...)` call):
//   - `.completed`     — stream finished naturally.
//   - `.targetGone`    — `WindowRectTracker` reported the target window
//                        is gone mid-stream (ADR 0007 Decision 2). The
//                        cycler skips this target for the rest of the
//                        iteration and continues on the next outer pass.
//   - `.focusStolen`   — `focusGuard` returned false (the cycler's
//                        post-fire focus-theft check from D-1 lifted
//                        into the player loop). The cycler reacts the
//                        same way it does in the legacy step path:
//                        abort remaining actions on this target.
//   - `.cancelled`     — `Task.cancel()` was called on the surrounding
//                        task (cycler.stop() during playback).
//
// Cleanup discipline: any keyDown or mouseDown the player issued without
// a matching keyUp / mouseUp yet gets released on outcome ≠ .completed.
// Otherwise the game thinks the key is still held when the cycler
// transitions to .stopped / next target — leads to "stuck character
// running forward" footguns.
//
// Coord system: `WindowRectTracker` stores AX (top-left origin) screen
// rects. `AutoKeysAction.rel` is window-relative top-left. The player
// adds rect.origin to rel without any axis flip — CGEvent's mouse
// coordinate system is also top-left. One coordinate system end-to-end;
// the recorder (D-3.3) flips NSEvent (bottom-left) to top-left at
// capture time so the player never sees mixed conventions.

import CoreGraphics
import Foundation

public actor ActionStreamPlayer {

    public typealias FocusGuard = @Sendable () async -> Bool

    public enum Outcome: Equatable, Sendable {
        case completed
        case targetGone
        case focusStolen
        case cancelled
    }

    private let keyPoster: KeyEventPoster
    private let mousePoster: MouseEventPoster
    private let sleeper: Sleeper
    private let tracker: WindowRectTracker

    public init(
        keyPoster: KeyEventPoster,
        mousePoster: MouseEventPoster,
        sleeper: Sleeper,
        tracker: WindowRectTracker
    ) {
        self.keyPoster = keyPoster
        self.mousePoster = mousePoster
        self.sleeper = sleeper
        self.tracker = tracker
    }

    /// Replay `actions` against the given target pid. The caller (the
    /// cycler) is responsible for `focuser.focus(pid:)` BEFORE calling
    /// `play(...)` and for refreshing the tracker rect. The player
    /// re-reads the rect on every action so window moves mid-stream
    /// land at the right absolute coord.
    ///
    /// `focusGuard` mirrors D-1's post-fire focus-theft check from the
    /// legacy step path. The cycler passes a closure that reads the
    /// current frontmost pid and compares against the target.
    public func play(
        actions: [AutoKeysAction],
        targetPid: pid_t,
        focusGuard: @escaping FocusGuard
    ) async -> Outcome {
        var heldKeys: [(CGKeyCode, UInt)] = []
        var heldButtons: [(MouseButton, CGPoint)] = []

        for action in actions {
            if Task.isCancelled {
                await releaseHeld(keys: heldKeys, buttons: heldButtons)
                return .cancelled
            }

            // Sleep the inter-action gap before firing. dt is the delay
            // *before* this action.
            try? await sleeper.sleep(seconds: action.dt)

            if Task.isCancelled {
                await releaseHeld(keys: heldKeys, buttons: heldButtons)
                return .cancelled
            }

            // Re-read the rect every action — captures window moves
            // happening mid-stream. ADR 0007 Decision 2: target gone
            // (rect == nil) is skip-and-continue at the cycler level.
            guard let rect = await tracker.rect(for: targetPid) else {
                NSLog("[RORORO] player: target pid=\(targetPid) gone mid-stream — aborting (Decision 2)")
                await releaseHeld(keys: heldKeys, buttons: heldButtons)
                return .targetGone
            }

            switch action {
            case let .keyDown(keyCode, modifiers, _):
                await keyPoster.postDown(keyCode: keyCode, modifiers: modifiers)
                heldKeys.append((keyCode, modifiers))

            case let .keyUp(keyCode, modifiers, _):
                await keyPoster.postUp(keyCode: keyCode, modifiers: modifiers)
                heldKeys.removeAll { $0.0 == keyCode }

            case let .mouseMove(rel, _):
                let absolute = absolutePosition(rel: rel, rect: rect)
                await mousePoster.postMove(to: absolute)

            case let .mouseDown(button, rel, _):
                let absolute = absolutePosition(rel: rel, rect: rect)
                await mousePoster.postDown(button: button, at: absolute)
                heldButtons.append((button, absolute))

            case let .mouseUp(button, rel, _):
                let absolute = absolutePosition(rel: rel, rect: rect)
                await mousePoster.postUp(button: button, at: absolute)
                heldButtons.removeAll { $0.0 == button }
            }

            // Post-fire focus-theft check — mirror of the legacy step
            // path's check. Done AFTER the post so a single in-flight
            // event still lands; subsequent events abort.
            if !(await focusGuard()) {
                NSLog("[RORORO] player: focus moved away from pid=\(targetPid) mid-stream — aborting")
                await releaseHeld(keys: heldKeys, buttons: heldButtons)
                return .focusStolen
            }
        }

        return .completed
    }

    // MARK: - Helpers

    private func absolutePosition(rel: CGPoint, rect: CGRect) -> CGPoint {
        // Clamp to the window rect — out-of-window relatives can happen
        // if the user resized the window down since recording. ADR 0007
        // Decision 2 documents the clamp.
        let maxX = rect.origin.x + max(rect.width - 1, 0)
        let maxY = rect.origin.y + max(rect.height - 1, 0)
        let absX = min(max(rect.origin.x + rel.x, rect.origin.x), maxX)
        let absY = min(max(rect.origin.y + rel.y, rect.origin.y), maxY)
        return CGPoint(x: absX, y: absY)
    }

    /// Emit balancing keyUp / mouseUp for any held inputs at abort time.
    /// Last-on-first-off — release the most recently held key first so
    /// the game sees the natural "fingers come off the keys" order.
    private func releaseHeld(
        keys: [(CGKeyCode, UInt)],
        buttons: [(MouseButton, CGPoint)]
    ) async {
        for (keyCode, modifiers) in keys.reversed() {
            await keyPoster.postUp(keyCode: keyCode, modifiers: modifiers)
        }
        for (button, position) in buttons.reversed() {
            await mousePoster.postUp(button: button, at: position)
        }
    }
}
