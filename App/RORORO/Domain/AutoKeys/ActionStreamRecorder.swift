// ActionStreamRecorder.swift
// Domain — capture engine for the D-3 record-and-replay slope
// (ADR 0007). Consumes events from a `RecorderEventSource`, measures
// per-action `dt` via a `MonotonicClock`, translates absolute mouse
// coords to window-relative via `WindowRectTracker`, and emits a
// `[AutoKeysAction]` stream that `ActionStreamPlayer` replays verbatim.
//
// Capture rules (ADR 0007 Decision 3):
//   - Frontmost-only: events arriving while the target pid is not
//     frontmost are dropped, AND `isCapturePaused` flips true so the
//     UI can surface "paused — Roblox not frontmost". The pause itself
//     is NOT recorded as actions; on focus return, the next captured
//     action gets `dt = 0` (no phantom long-gap injected at replay).
//   - 500-action cap (ADR 0007 Decision 1): refuses further appends
//     past `AutoKeysSequence.maxActionCount`; flips `didCap` for the
//     UI's cap banner.
//   - Self-tagged events (cycler-fired) ignored — paranoia against a
//     parallel cycler run leaking events into the recording.
//
// Coord system: positions come from the event source as top-left screen
// coords (matching the tracker's AX convention). `rel` is stored as
// `position - rect.origin`. One coord system end-to-end — no flip,
// no chance of mirroring.
//
// Not an observable @MainActor type — the UI in D-3.4 will read state
// via async accessors (`currentCount()`, `elapsed()`, `isCapturePaused()`,
// `didCap()`) and bridge to SwiftUI through a view-model layer. Keeps
// this type purely a domain actor.

import CoreGraphics
import Foundation

public actor ActionStreamRecorder {

    public enum Status: Equatable, Sendable {
        case idle
        case recording
        case stopped
    }

    private let source: RecorderEventSource
    private let tracker: WindowRectTracker
    private let frontmost: FrontmostAppProvider
    private let clock: MonotonicClock

    private var status: Status = .idle
    private var targetPid: pid_t?
    private var actions: [AutoKeysAction] = []
    private var startTime: TimeInterval?
    /// The clock value of the most recent appended action. Reset to nil
    /// on start, and on every capture-pause (so the next action after
    /// resume gets `dt = 0` instead of "real elapsed since last action").
    private var lastActionTime: TimeInterval?
    private var capturePaused: Bool = false
    private var didCap: Bool = false
    private var ingestTask: Task<Void, Never>?

    public init(
        source: RecorderEventSource,
        tracker: WindowRectTracker,
        frontmost: FrontmostAppProvider,
        clock: MonotonicClock = CACurrentMediaClock()
    ) {
        self.source = source
        self.tracker = tracker
        self.frontmost = frontmost
        self.clock = clock
    }

    // MARK: - Lifecycle

    /// Begin recording for `targetPid`. The caller has already focused
    /// the Roblox window and refreshed the tracker rect (the recorder
    /// re-reads the rect on every mouse event so window moves during
    /// recording are captured correctly).
    public func start(targetPid: pid_t) async {
        if status == .recording {
            // Idempotent — restarting clears state.
            await stop()
        }
        self.targetPid = targetPid
        self.actions = []
        self.startTime = clock.now()
        self.lastActionTime = nil
        self.capturePaused = false
        self.didCap = false
        self.status = .recording

        let stream = source.start()
        ingestTask = Task { [weak self] in
            for await event in stream {
                if Task.isCancelled { return }
                await self?.ingest(event: event)
            }
        }
    }

    /// Stop recording and return the captured action stream. Calling
    /// twice or while idle returns the last captured stream (or empty).
    @discardableResult
    public func stop() async -> [AutoKeysAction] {
        ingestTask?.cancel()
        ingestTask = nil
        source.stop()
        status = .stopped
        return actions
    }

    // MARK: - Read state (for UI)

    public func currentCount() -> Int { actions.count }
    public func elapsed() -> TimeInterval {
        guard let start = startTime else { return 0 }
        return clock.now() - start
    }
    public func isCapturePaused() -> Bool { capturePaused }
    public func didReachCap() -> Bool { didCap }
    public func currentStatus() -> Status { status }
    public func snapshot() -> [AutoKeysAction] { actions }

    // MARK: - Ingest

    private func ingest(event: RecorderEvent) async {
        guard status == .recording else { return }
        guard !event.isSelfTagged else { return }
        guard let target = targetPid else { return }

        // Frontmost gating — capture pauses without recording the gap.
        // Re-read every event because focus changes don't fire on every
        // monitor tick; the frontmost pid is the source of truth.
        let front = await frontmost.currentFrontmostPid()
        let isFront = (front == target)
        if !isFront {
            if !capturePaused {
                capturePaused = true
                // Reset the lastActionTime so the FIRST action after
                // resume gets dt=0. The plan's UX contract: pause time
                // doesn't replay as a phantom long delay.
                lastActionTime = nil
            }
            return
        }
        if capturePaused {
            capturePaused = false
            // Still reset on transition so the first post-resume action
            // has dt=0. (Belt + suspenders — already nil'd on pause.)
            lastActionTime = nil
        }

        // Cap check — refuse further appends but keep ingest running so
        // the UI's banner-flip flag flips reliably.
        if actions.count >= AutoKeysSequence.maxActionCount {
            didCap = true
            return
        }

        // dt — time since the last appended action. nil → 0 (first
        // action ever, or first after a capture-pause).
        let now = clock.now()
        let dt = lastActionTime.map { now - $0 } ?? 0

        guard let action = await buildAction(from: event, target: target, dt: dt) else {
            return
        }
        actions.append(action)
        lastActionTime = now
    }

    /// Translate a `RecorderEvent` into the corresponding
    /// `AutoKeysAction` with window-relative `rel`. Returns nil if the
    /// tracker can't supply a rect for the target (mouse events) — the
    /// recorder skips the event and continues; the user typically
    /// doesn't notice because tracker rects refresh on focus.
    private func buildAction(
        from event: RecorderEvent,
        target: pid_t,
        dt: TimeInterval
    ) async -> AutoKeysAction? {
        switch event.kind {
        case let .keyDown(keyCode):
            return .keyDown(keyCode: keyCode, modifiers: event.modifiers, dt: dt)
        case let .keyUp(keyCode):
            return .keyUp(keyCode: keyCode, modifiers: event.modifiers, dt: dt)
        case .mouseMoved:
            guard let pos = event.position, let rect = await tracker.rect(for: target) else { return nil }
            return .mouseMove(rel: relative(pos, in: rect), dt: dt)
        case let .mouseDown(button):
            guard let pos = event.position, let rect = await tracker.rect(for: target) else { return nil }
            return .mouseDown(button, rel: relative(pos, in: rect), dt: dt)
        case let .mouseUp(button):
            guard let pos = event.position, let rect = await tracker.rect(for: target) else { return nil }
            return .mouseUp(button, rel: relative(pos, in: rect), dt: dt)
        }
    }

    private func relative(_ position: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: position.x - rect.origin.x, y: position.y - rect.origin.y)
    }
}
