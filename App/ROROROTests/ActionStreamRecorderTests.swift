// ActionStreamRecorderTests.swift
// Wave D-3.3 — capture engine. Fakes for RecorderEventSource +
// FrontmostAppProvider + MonotonicClock so the test drives event
// arrival, focus transitions, and clock advances deterministically.

import CoreGraphics
import XCTest
@testable import RORORO

final class ActionStreamRecorderTests: XCTestCase {

    // MARK: - Fakes

    final class FakeRecorderEventSource: RecorderEventSource, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<RecorderEvent>.Continuation?
        private(set) var stopCallCount = 0

        func start() -> AsyncStream<RecorderEvent> {
            AsyncStream { c in
                lock.lock(); continuation = c; lock.unlock()
            }
        }

        func stop() {
            lock.lock()
            continuation?.finish()
            continuation = nil
            stopCallCount += 1
            lock.unlock()
        }

        func send(_ event: RecorderEvent) async {
            lock.lock(); let c = continuation; lock.unlock()
            c?.yield(event)
            // Yield to let the recorder's ingest Task pick the event up.
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
    }

    final class FakeFrontmostAppProvider: FrontmostAppProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var _pid: pid_t?
        func setFrontmost(_ pid: pid_t?) {
            lock.lock(); _pid = pid; lock.unlock()
        }
        func currentFrontmostPid() async -> pid_t? {
            lock.lock(); defer { lock.unlock() }
            return _pid
        }
    }

    final class FakeMonotonicClock: MonotonicClock, @unchecked Sendable {
        private let lock = NSLock()
        private var _t: TimeInterval = 0
        func setTime(_ t: TimeInterval) {
            lock.lock(); _t = t; lock.unlock()
        }
        func advance(by delta: TimeInterval) {
            lock.lock(); _t += delta; lock.unlock()
        }
        func now() -> TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return _t
        }
    }

    // MARK: - Helpers

    private func makeRecorder(
        source: FakeRecorderEventSource,
        frontmost: FakeFrontmostAppProvider,
        clock: FakeMonotonicClock,
        trackerPid: pid_t,
        trackerRect: CGRect
    ) async -> ActionStreamRecorder {
        let provider = FakeAXRectProvider()
        provider.setRect(trackerRect, for: trackerPid)
        let tracker = WindowRectTracker(provider: provider)
        await tracker.refresh(pid: trackerPid)
        return ActionStreamRecorder(
            source: source,
            tracker: tracker,
            frontmost: frontmost,
            clock: clock
        )
    }

    // MARK: - Verbatim capture

    func testStart_CapturesKeyDownThenMouseThenKeyUp_VerbatimWithDt() async {
        let src = FakeRecorderEventSource()
        let front = FakeFrontmostAppProvider()
        front.setFrontmost(100)
        let clock = FakeMonotonicClock()
        clock.setTime(1000.0)

        let recorder = await makeRecorder(
            source: src,
            frontmost: front,
            clock: clock,
            trackerPid: 100,
            trackerRect: CGRect(x: 50, y: 50, width: 800, height: 600)
        )

        await recorder.start(targetPid: 100)

        // Action 1 at t=1000 — first action, dt=0 by contract.
        await src.send(RecorderEvent(kind: .keyDown(13), modifiers: 0))

        clock.advance(by: 0.020)
        // Action 2 at t=1000.020 — dt = 0.020.
        await src.send(RecorderEvent(
            kind: .mouseMoved,
            position: CGPoint(x: 150, y: 150)
        ))

        clock.advance(by: 0.050)
        // Action 3 at t=1000.070 — dt = 0.050.
        await src.send(RecorderEvent(kind: .keyUp(13), modifiers: 0))

        let actions = await recorder.stop()

        XCTAssertEqual(actions.count, 3)

        // dt[0] = 0 (first action)
        XCTAssertEqual(actions[0], .keyDown(keyCode: 13, modifiers: 0, dt: 0))

        // dt[1] = 0.020 (elapsed since action 0). rel = pos - origin =
        // (150, 150) - (50, 50) = (100, 100).
        if case let .mouseMove(rel, dt) = actions[1] {
            XCTAssertEqual(rel, CGPoint(x: 100, y: 100))
            XCTAssertEqual(dt, 0.020, accuracy: 0.0001)
        } else {
            XCTFail("Expected mouseMove, got \(actions[1])")
        }

        // dt[2] = 0.050.
        if case let .keyUp(keyCode, modifiers, dt) = actions[2] {
            XCTAssertEqual(keyCode, 13)
            XCTAssertEqual(modifiers, 0)
            XCTAssertEqual(dt, 0.050, accuracy: 0.0001)
        } else {
            XCTFail("Expected keyUp, got \(actions[2])")
        }
    }

    // MARK: - Frontmost gating

    func testIngest_EventArrivingWhileNotFrontmost_IsDropped() async {
        let src = FakeRecorderEventSource()
        let front = FakeFrontmostAppProvider()
        front.setFrontmost(999) // some other app
        let clock = FakeMonotonicClock()

        let recorder = await makeRecorder(
            source: src,
            frontmost: front,
            clock: clock,
            trackerPid: 100,
            trackerRect: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        await recorder.start(targetPid: 100)
        await src.send(RecorderEvent(kind: .keyDown(49), modifiers: 0))

        let count = await recorder.currentCount()
        XCTAssertEqual(count, 0)
        let paused = await recorder.isCapturePaused()
        XCTAssertTrue(paused)

        _ = await recorder.stop()
    }

    func testIngest_FocusReturnsMidRecord_DtZeroOnFirstResumeAction() async {
        let src = FakeRecorderEventSource()
        let front = FakeFrontmostAppProvider()
        front.setFrontmost(100)
        let clock = FakeMonotonicClock()
        clock.setTime(100.0)

        let recorder = await makeRecorder(
            source: src,
            frontmost: front,
            clock: clock,
            trackerPid: 100,
            trackerRect: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        await recorder.start(targetPid: 100)

        // Action 1 captured while frontmost.
        await src.send(RecorderEvent(kind: .keyDown(13), modifiers: 0))

        // User Cmd-Tabs to Safari.
        front.setFrontmost(999)
        clock.advance(by: 30) // 30 seconds of "pause"
        // Event during pause — dropped.
        await src.send(RecorderEvent(kind: .keyDown(49), modifiers: 0))

        // Focus returns to Roblox.
        front.setFrontmost(100)
        clock.advance(by: 0.5)
        // First post-resume action — dt should be 0, NOT 30.5s.
        await src.send(RecorderEvent(kind: .keyDown(0), modifiers: 0))

        let actions = await recorder.stop()

        XCTAssertEqual(actions.count, 2, "Pause event leaked: \(actions)")
        XCTAssertEqual(actions[0], .keyDown(keyCode: 13, modifiers: 0, dt: 0))
        // dt[1] = 0 because we crossed a pause/resume boundary.
        XCTAssertEqual(actions[1], .keyDown(keyCode: 0, modifiers: 0, dt: 0))
    }

    func testIngest_PauseFlagToggles_WithFocusTransition() async {
        let src = FakeRecorderEventSource()
        let front = FakeFrontmostAppProvider()
        front.setFrontmost(100)
        let clock = FakeMonotonicClock()

        let recorder = await makeRecorder(
            source: src,
            frontmost: front,
            clock: clock,
            trackerPid: 100,
            trackerRect: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        await recorder.start(targetPid: 100)

        // Frontmost → paused: false initially.
        let initiallyPaused = await recorder.isCapturePaused()
        XCTAssertFalse(initiallyPaused)

        // Focus leaves; send an event so the recorder observes the gap.
        front.setFrontmost(999)
        await src.send(RecorderEvent(kind: .keyDown(13), modifiers: 0))
        let pausedDuringOffFocus = await recorder.isCapturePaused()
        XCTAssertTrue(pausedDuringOffFocus)

        // Focus returns; send an event so the flag toggles back.
        front.setFrontmost(100)
        await src.send(RecorderEvent(kind: .keyDown(49), modifiers: 0))
        let resumedPaused = await recorder.isCapturePaused()
        XCTAssertFalse(resumedPaused)

        _ = await recorder.stop()
    }

    // MARK: - Coord translation

    func testIngest_MouseEvent_TranslatesPositionToWindowRelative() async {
        let src = FakeRecorderEventSource()
        let front = FakeFrontmostAppProvider()
        front.setFrontmost(100)
        let clock = FakeMonotonicClock()

        let recorder = await makeRecorder(
            source: src,
            frontmost: front,
            clock: clock,
            trackerPid: 100,
            // Roblox window at (200, 300) sized 1024×768.
            trackerRect: CGRect(x: 200, y: 300, width: 1024, height: 768)
        )

        await recorder.start(targetPid: 100)
        await src.send(RecorderEvent(
            kind: .mouseDown(.left),
            position: CGPoint(x: 250, y: 350) // 50 in, 50 down
        ))

        let actions = await recorder.stop()
        XCTAssertEqual(actions.count, 1)
        if case let .mouseDown(button, rel, _) = actions[0] {
            XCTAssertEqual(button, .left)
            XCTAssertEqual(rel, CGPoint(x: 50, y: 50))
        } else {
            XCTFail("Expected mouseDown, got \(actions[0])")
        }
    }

    // MARK: - 500-action cap

    func testIngest_AppendsRefusedPastCap_FlipsCapFlag() async {
        let src = FakeRecorderEventSource()
        let front = FakeFrontmostAppProvider()
        front.setFrontmost(100)
        let clock = FakeMonotonicClock()

        let recorder = await makeRecorder(
            source: src,
            frontmost: front,
            clock: clock,
            trackerPid: 100,
            trackerRect: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        await recorder.start(targetPid: 100)

        // Fire exactly maxActionCount + 5 keyboard events. Use the
        // recorder's actor-internal API to bulk-send to avoid 505 round-
        // trips through the AsyncStream (each takes ~5ms in this test).
        for _ in 0..<(AutoKeysSequence.maxActionCount + 5) {
            await src.send(RecorderEvent(kind: .keyDown(49), modifiers: 0))
        }

        let actions = await recorder.stop()
        XCTAssertEqual(actions.count, AutoKeysSequence.maxActionCount)
        let capped = await recorder.didReachCap()
        XCTAssertTrue(capped)
    }

    // MARK: - Self-tag filter

    func testIngest_SelfTaggedEvent_IsDropped() async {
        let src = FakeRecorderEventSource()
        let front = FakeFrontmostAppProvider()
        front.setFrontmost(100)
        let clock = FakeMonotonicClock()

        let recorder = await makeRecorder(
            source: src,
            frontmost: front,
            clock: clock,
            trackerPid: 100,
            trackerRect: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        await recorder.start(targetPid: 100)
        await src.send(RecorderEvent(
            kind: .keyDown(49),
            modifiers: 0,
            isSelfTagged: true
        ))

        let count = await recorder.currentCount()
        XCTAssertEqual(count, 0)
        _ = await recorder.stop()
    }

    // MARK: - D-3.4.1 — hotkey-driven start/stop

    /// The default Ctrl+Opt+Shift+P chord — same constant
    /// `LaunchSettingsStore.defaultRecorderHotkey` uses in production.
    private static let testHotkey = KillKeyCombo(
        keyCode: 35,
        modifiers: (1 << 17) | (1 << 18) | (1 << 19)
    )

    func testStart_WithHotkey_StaysArmedUntilChordPressed() async {
        let src = FakeRecorderEventSource()
        let front = FakeFrontmostAppProvider()
        front.setFrontmost(100)
        let clock = FakeMonotonicClock()

        let recorder = await makeRecorder(
            source: src,
            frontmost: front,
            clock: clock,
            trackerPid: 100,
            trackerRect: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        await recorder.start(targetPid: 100, hotkey: Self.testHotkey)

        let armed = await recorder.currentStatus()
        XCTAssertEqual(armed, .armed)

        // Non-chord events while armed are dropped.
        await src.send(RecorderEvent(kind: .keyDown(13), modifiers: 0))
        let count = await recorder.currentCount()
        XCTAssertEqual(count, 0)
        let stillArmed = await recorder.currentStatus()
        XCTAssertEqual(stillArmed, .armed)

        _ = await recorder.stop()
    }

    func testHotkeyPress_TransitionsArmedToActive_AndDropsChordFromStream() async {
        let src = FakeRecorderEventSource()
        let front = FakeFrontmostAppProvider()
        front.setFrontmost(100)
        let clock = FakeMonotonicClock()
        clock.setTime(200.0)

        let recorder = await makeRecorder(
            source: src,
            frontmost: front,
            clock: clock,
            trackerPid: 100,
            trackerRect: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        await recorder.start(targetPid: 100, hotkey: Self.testHotkey)

        // User presses Ctrl+Opt+Shift+P — chord keyDown lands.
        await src.send(RecorderEvent(
            kind: .keyDown(Self.testHotkey.keyCode),
            modifiers: Self.testHotkey.modifiers
        ))

        let active = await recorder.currentStatus()
        XCTAssertEqual(active, .active)

        // Paired keyUp of the chord — should also drop, never reach
        // the captured stream.
        await src.send(RecorderEvent(
            kind: .keyUp(Self.testHotkey.keyCode),
            modifiers: Self.testHotkey.modifiers
        ))

        // First real action AFTER going active — dt=0 by contract
        // (lastActionTime resets on the armed→active transition, same
        // mechanic as the pause/resume dt-zero invariant).
        clock.advance(by: 0.5)
        await src.send(RecorderEvent(kind: .keyDown(13), modifiers: 0))
        // Second action exercises the real dt math.
        clock.advance(by: 0.2)
        await src.send(RecorderEvent(kind: .keyUp(13), modifiers: 0))

        let actions = await recorder.stop()
        XCTAssertEqual(actions.count, 2, "Chord events leaked into stream: \(actions)")
        XCTAssertEqual(actions[0], .keyDown(keyCode: 13, modifiers: 0, dt: 0))
        // dt arithmetic — break out for accuracy comparison.
        if case let .keyUp(kc, mods, dt) = actions[1] {
            XCTAssertEqual(kc, 13)
            XCTAssertEqual(mods, 0)
            XCTAssertEqual(dt, 0.2, accuracy: 0.0001)
        } else {
            XCTFail("Expected keyUp, got \(actions[1])")
        }
    }

    func testSecondHotkeyPress_TransitionsActiveToStopped() async {
        let src = FakeRecorderEventSource()
        let front = FakeFrontmostAppProvider()
        front.setFrontmost(100)
        let clock = FakeMonotonicClock()

        let recorder = await makeRecorder(
            source: src,
            frontmost: front,
            clock: clock,
            trackerPid: 100,
            trackerRect: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        await recorder.start(targetPid: 100, hotkey: Self.testHotkey)

        // First chord press → active.
        await src.send(RecorderEvent(
            kind: .keyDown(Self.testHotkey.keyCode),
            modifiers: Self.testHotkey.modifiers
        ))
        await src.send(RecorderEvent(
            kind: .keyUp(Self.testHotkey.keyCode),
            modifiers: Self.testHotkey.modifiers
        ))

        await src.send(RecorderEvent(kind: .keyDown(13), modifiers: 0))

        // Second chord press → stopped.
        await src.send(RecorderEvent(
            kind: .keyDown(Self.testHotkey.keyCode),
            modifiers: Self.testHotkey.modifiers
        ))

        let stopped = await recorder.currentStatus()
        XCTAssertEqual(stopped, .stopped)

        // Events arriving AFTER the stop chord are dropped — recorder
        // ignores its event stream once stopped.
        await src.send(RecorderEvent(kind: .keyDown(49), modifiers: 0))

        let actions = await recorder.stop()
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0], .keyDown(keyCode: 13, modifiers: 0, dt: 0))
    }

    func testHotkey_CmdTabBeforeStart_DoesNotLeakIntoStream() async {
        // Reproduce the original UX bug. User clicks Record in the
        // sheet (RORORO frontmost), Cmd-Tabs to Roblox, then presses
        // the chord to start. The Cmd press/release events MUST NOT
        // appear in the captured stream.
        let src = FakeRecorderEventSource()
        let front = FakeFrontmostAppProvider()
        front.setFrontmost(999) // RORORO pid (target is Roblox = 100)
        let clock = FakeMonotonicClock()

        let recorder = await makeRecorder(
            source: src,
            frontmost: front,
            clock: clock,
            trackerPid: 100,
            trackerRect: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        await recorder.start(targetPid: 100, hotkey: Self.testHotkey)

        // User presses Cmd-Tab while RORORO is frontmost. Cmd is a
        // modifier-only event so it doesn't surface as keyDown(Cmd) —
        // but the Tab keystroke does. Dropped because we're armed.
        await src.send(RecorderEvent(kind: .keyDown(48), modifiers: 1 << 20)) // Tab + Cmd

        // macOS switches to Roblox — frontmost flips.
        front.setFrontmost(100)

        // Cmd-Tab release fires as keyUp(Tab) with modifiers=Cmd. The
        // pre-D-3.4.1 bug captured this as the first action.
        await src.send(RecorderEvent(kind: .keyUp(48), modifiers: 1 << 20))

        // User presses the chord to start.
        await src.send(RecorderEvent(
            kind: .keyDown(Self.testHotkey.keyCode),
            modifiers: Self.testHotkey.modifiers
        ))
        await src.send(RecorderEvent(
            kind: .keyUp(Self.testHotkey.keyCode),
            modifiers: Self.testHotkey.modifiers
        ))

        // Now capture is active. User does their thing.
        await src.send(RecorderEvent(kind: .keyDown(13), modifiers: 0))

        let actions = await recorder.stop()
        XCTAssertEqual(actions.count, 1, "Cmd-Tab leaked: \(actions)")
        XCTAssertEqual(actions[0], .keyDown(keyCode: 13, modifiers: 0, dt: 0))
    }

    func testHotkey_MismatchedModifiers_DoesNotTrigger() async {
        let src = FakeRecorderEventSource()
        let front = FakeFrontmostAppProvider()
        front.setFrontmost(100)
        let clock = FakeMonotonicClock()

        let recorder = await makeRecorder(
            source: src,
            frontmost: front,
            clock: clock,
            trackerPid: 100,
            trackerRect: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        await recorder.start(targetPid: 100, hotkey: Self.testHotkey)

        // Bare P (no modifiers) — should NOT trigger; recorder stays armed.
        await src.send(RecorderEvent(kind: .keyDown(Self.testHotkey.keyCode), modifiers: 0))

        let stillArmed = await recorder.currentStatus()
        XCTAssertEqual(stillArmed, .armed)

        _ = await recorder.stop()
    }

    // MARK: - Round-trip with the player

    func testCaptureThenReplay_RoundTripsThroughPlayerVerbatim() async {
        // End-to-end shape: record some actions, hand the resulting
        // stream to the player, and verify the same actions come back
        // out the other side as posted events.
        let recorderSrc = FakeRecorderEventSource()
        let front = FakeFrontmostAppProvider()
        front.setFrontmost(100)
        let clock = FakeMonotonicClock()
        clock.setTime(50.0)

        let recorder = await makeRecorder(
            source: recorderSrc,
            frontmost: front,
            clock: clock,
            trackerPid: 100,
            trackerRect: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        await recorder.start(targetPid: 100)
        await recorderSrc.send(RecorderEvent(kind: .keyDown(13), modifiers: 0))
        clock.advance(by: 0.020)
        await recorderSrc.send(RecorderEvent(
            kind: .mouseDown(.left),
            position: CGPoint(x: 100, y: 100)
        ))
        clock.advance(by: 0.050)
        await recorderSrc.send(RecorderEvent(
            kind: .mouseUp(.left),
            position: CGPoint(x: 100, y: 100)
        ))
        clock.advance(by: 0.020)
        await recorderSrc.send(RecorderEvent(kind: .keyUp(13), modifiers: 0))

        let captured = await recorder.stop()
        XCTAssertEqual(captured.count, 4)

        // Replay through the player against an aligned tracker.
        let keyPoster = ActionStreamPlayerTests.RecordingKeyPoster()
        let mousePoster = ActionStreamPlayerTests.RecordingMousePoster()
        let provider = FakeAXRectProvider()
        provider.setRect(CGRect(x: 0, y: 0, width: 800, height: 600), for: 100)
        let tracker = WindowRectTracker(provider: provider)
        await tracker.refresh(pid: 100)

        let player = ActionStreamPlayer(
            keyPoster: keyPoster,
            mousePoster: mousePoster,
            sleeper: ActionStreamPlayerTests.RecordingSleeper(),
            tracker: tracker
        )

        _ = await player.play(
            actions: captured,
            targetPid: 100,
            focusGuard: { true }
        )

        XCTAssertEqual(keyPoster.snapshot(), [
            .down(13, 0),
            .up(13, 0),
        ])
        XCTAssertEqual(mousePoster.snapshot(), [
            .down(.left, CGPoint(x: 100, y: 100)),
            .up(.left, CGPoint(x: 100, y: 100)),
        ])
    }
}
