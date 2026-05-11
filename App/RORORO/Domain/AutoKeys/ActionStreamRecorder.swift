// ActionStreamRecorder.swift
// Domain — capture engine for the D-3 record-and-replay slope
// (ADR 0007). Consumes events from a `RecorderEventSource`, measures
// per-action `dt` via a `MonotonicClock`, translates absolute mouse
// coords to window-relative via `WindowRectTracker`, and emits a
// `[AutoKeysAction]` stream that `ActionStreamPlayer` replays verbatim.
//
// Capture rules (ADR 0007 Decision 3 + D-3.4.1 hotkey gate):
//   - Optional global hotkey (D-3.4.1): if `start(targetPid:hotkey:)`
//     is called with a `KillKeyCombo`, the recorder enters `.armed`
//     and ignores events until the hotkey is pressed — at which point
//     it transitions to `.active`. Pressing the hotkey a second time
//     transitions `.active` → `.stopped`. The chord's keyDown AND the
//     paired keyUp are filtered from the captured stream so the
//     recording never contains the chord itself. Avoids the Cmd-Tab
//     leak: user clicks Record (recorder armed), Cmd-Tabs to Roblox,
//     presses the chord, does their thing, presses the chord again.
//     The Cmd press/release lands during `.armed` and is dropped.
//     When `hotkey` is nil, the recorder skips the armed phase and
//     starts capturing immediately (matches pre-D-3.4.1 semantics).
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
        /// Recorder started with a hotkey; ignoring events until the
        /// hotkey is pressed. The Cmd-Tab and any other input the user
        /// performs to get to Roblox lands here and is discarded.
        case armed
        /// Capture is live — events flow into the action stream.
        case active
        /// Capture ended (via the hotkey, or via explicit `stop()`).
        case stopped
    }

    private let source: RecorderEventSource
    private let tracker: WindowRectTracker
    private let frontmost: FrontmostAppProvider
    private let clock: MonotonicClock

    private var status: Status = .idle
    private var targetPid: pid_t?
    private var hotkey: KillKeyCombo?
    private var actions: [AutoKeysAction] = []
    /// Wall-clock (monotonic) of the transition into `.active` — the
    /// moment capture actually starts producing actions. nil until then.
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

    /// Begin recording for `targetPid`. When `hotkey` is non-nil, the
    /// recorder enters `.armed` and ignores events until the user
    /// presses the chord — that transition flips capture to `.active`.
    /// Pass nil to skip the armed phase (matches pre-D-3.4.1 callers
    /// and unit tests that drive events directly).
    public func start(targetPid: pid_t, hotkey: KillKeyCombo? = nil) async {
        if status == .armed || status == .active {
            // Idempotent — restarting clears state.
            await stop()
        }
        self.targetPid = targetPid
        self.hotkey = hotkey
        self.actions = []
        self.lastActionTime = nil
        self.capturePaused = false
        self.didCap = false
        if hotkey == nil {
            // No-hotkey path: capture is live from the first event.
            self.startTime = clock.now()
            self.status = .active
        } else {
            // Wait for the chord. startTime sets on transition to active.
            self.startTime = nil
            self.status = .armed
        }

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
        guard status == .armed || status == .active else { return }
        guard !event.isSelfTagged else { return }
        guard let target = targetPid else { return }

        // Hotkey gate — runs BEFORE the frontmost filter so the chord
        // works globally (user might be in Roblox OR cmd-tabbed to
        // RORORO when they press it). Match against keyDown only; the
        // paired keyUp gets dropped below so the chord never appears
        // in the captured stream.
        if let hotkey, matchesHotkey(event: event, hotkey: hotkey) {
            if case .keyDown = event.kind {
                switch status {
                case .armed:
                    // Transition to active. Reset the dt clock so the
                    // first captured action gets dt=0.
                    status = .active
                    startTime = clock.now()
                    lastActionTime = nil
                case .active:
                    // Second chord press ends the recording. The
                    // event source stays alive until stop() is called
                    // by the view-model, but no further events are
                    // captured.
                    status = .stopped
                case .idle, .stopped:
                    return
                }
            }
            // Drop both keyDown and keyUp of the chord from the stream.
            return
        }

        guard status == .active else { return }

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

    /// True iff the event is the bare key of the configured hotkey
    /// chord — keyDown or keyUp of `hotkey.keyCode` while the held
    /// modifiers match `hotkey.modifiers`. The modifier match is
    /// equality (not subset) so a stray Cmd press doesn't spuriously
    /// trigger Ctrl+Opt+Shift+P.
    private func matchesHotkey(event: RecorderEvent, hotkey: KillKeyCombo) -> Bool {
        let keyCode: CGKeyCode
        switch event.kind {
        case let .keyDown(kc): keyCode = kc
        case let .keyUp(kc):   keyCode = kc
        default: return false
        }
        return keyCode == hotkey.keyCode && event.modifiers == hotkey.modifiers
    }
}
