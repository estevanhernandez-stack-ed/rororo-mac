// ActionStreamPlayerTests.swift
// Wave D-3.2 — covers the replay engine that the cycler's `.stream`
// variant dispatch routes to. Fakes for poster + tracker + sleeper so
// the test is a pure orchestration check; the integration test against
// real `CGEvent` lives in the manual smoke pass at D-3.6.

import CoreGraphics
import XCTest
@testable import RORORO

@MainActor
final class ActionStreamPlayerTests: XCTestCase {

    // MARK: - Fakes

    final class RecordingKeyPoster: KeyEventPoster, @unchecked Sendable {
        enum Event: Equatable {
            case combined(CGKeyCode)
            case down(CGKeyCode, UInt)
            case up(CGKeyCode, UInt)
        }
        let lock = NSLock()
        private(set) var events: [Event] = []
        func post(keyCode: CGKeyCode) async {
            lock.lock(); defer { lock.unlock() }
            events.append(.combined(keyCode))
        }
        func postDown(keyCode: CGKeyCode, modifiers: UInt) async {
            lock.lock(); defer { lock.unlock() }
            events.append(.down(keyCode, modifiers))
        }
        func postUp(keyCode: CGKeyCode, modifiers: UInt) async {
            lock.lock(); defer { lock.unlock() }
            events.append(.up(keyCode, modifiers))
        }
        func snapshot() -> [Event] {
            lock.lock(); defer { lock.unlock() }
            return events
        }
    }

    final class RecordingMousePoster: MouseEventPoster, @unchecked Sendable {
        enum Event: Equatable {
            case move(CGPoint)
            case down(MouseButton, CGPoint)
            case up(MouseButton, CGPoint)
        }
        let lock = NSLock()
        private(set) var events: [Event] = []
        func postMove(to position: CGPoint) async {
            lock.lock(); defer { lock.unlock() }
            events.append(.move(position))
        }
        func postDown(button: MouseButton, at position: CGPoint) async {
            lock.lock(); defer { lock.unlock() }
            events.append(.down(button, position))
        }
        func postUp(button: MouseButton, at position: CGPoint) async {
            lock.lock(); defer { lock.unlock() }
            events.append(.up(button, position))
        }
        func snapshot() -> [Event] {
            lock.lock(); defer { lock.unlock() }
            return events
        }
    }

    /// Counts `sleep` calls and yields a tiny real suspension so the
    /// player can be cancelled mid-stream. Matches the pattern from
    /// AutoKeysCyclerTests.RecordingSleeper.
    final class RecordingSleeper: Sleeper, @unchecked Sendable {
        let lock = NSLock()
        private(set) var sleepRequests: [TimeInterval] = []
        func sleep(seconds: TimeInterval) async throws {
            lock.lock(); sleepRequests.append(seconds); lock.unlock()
            try await Task.sleep(nanoseconds: 1_000_000) // 1ms
        }
        func snapshot() -> [TimeInterval] {
            lock.lock(); defer { lock.unlock() }
            return sleepRequests
        }
    }

    /// Sleeps the actual requested duration via `Task.sleep` so the
    /// cancellation test can interrupt the player mid-sleep.
    /// `Task.sleep(nanoseconds:)` is cancellation-aware — throws
    /// CancellationError when the surrounding task is cancelled.
    final class RealTimeSleeper: Sleeper, @unchecked Sendable {
        func sleep(seconds: TimeInterval) async throws {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    // MARK: - Helpers

    private func makeTracker(for pid: pid_t, at rect: CGRect) async -> WindowRectTracker {
        let provider = FakeAXRectProvider()
        provider.setRect(rect, for: pid)
        let tracker = WindowRectTracker(provider: provider)
        await tracker.refresh(pid: pid)
        return tracker
    }

    // MARK: - Verbatim replay

    func testPlay_VerbatimReplay_PostsKeyDownThenMouseThenKeyUp() async {
        let key = RecordingKeyPoster()
        let mouse = RecordingMousePoster()
        let sleeper = RecordingSleeper()
        let tracker = await makeTracker(for: 100, at: CGRect(x: 50, y: 50, width: 800, height: 600))

        let player = ActionStreamPlayer(
            keyPoster: key,
            mousePoster: mouse,
            sleeper: sleeper,
            tracker: tracker
        )

        let actions: [AutoKeysAction] = [
            .keyDown(keyCode: 13, modifiers: 0, dt: 0),
            .mouseMove(rel: CGPoint(x: 100, y: 50), dt: 0.016),
            .mouseDown(.left, rel: CGPoint(x: 100, y: 50), dt: 0.080),
            .mouseUp(.left, rel: CGPoint(x: 100, y: 50), dt: 0.020),
            .keyUp(keyCode: 13, modifiers: 0, dt: 0.300),
        ]

        let outcome = await player.play(
            actions: actions,
            targetPid: 100,
            focusGuard: { true }
        )

        XCTAssertEqual(outcome, .completed)

        let keyEvents = key.snapshot()
        XCTAssertEqual(keyEvents, [
            .down(13, 0),
            .up(13, 0),
        ])

        let mouseEvents = mouse.snapshot()
        // Absolute = window origin (50, 50) + rel (100, 50) = (150, 100)
        XCTAssertEqual(mouseEvents, [
            .move(CGPoint(x: 150, y: 100)),
            .down(.left, CGPoint(x: 150, y: 100)),
            .up(.left, CGPoint(x: 150, y: 100)),
        ])

        // 5 actions × 1 sleep each = 5 dt sleeps.
        XCTAssertEqual(sleeper.snapshot().count, 5)
    }

    // MARK: - Window translation

    func testPlay_TranslatesRelToAbsoluteUsingTrackerRectOrigin() async {
        let mouse = RecordingMousePoster()
        let tracker = await makeTracker(for: 200, at: CGRect(x: 1000, y: 200, width: 800, height: 600))

        let player = ActionStreamPlayer(
            keyPoster: RecordingKeyPoster(),
            mousePoster: mouse,
            sleeper: RecordingSleeper(),
            tracker: tracker
        )

        _ = await player.play(
            actions: [.mouseMove(rel: CGPoint(x: 10, y: 20), dt: 0)],
            targetPid: 200,
            focusGuard: { true }
        )

        XCTAssertEqual(mouse.snapshot(), [.move(CGPoint(x: 1010, y: 220))])
    }

    // MARK: - Target gone mid-replay

    func testPlay_TargetWindowGoneMidStream_AbortsAndReturnsTargetGone() async {
        let key = RecordingKeyPoster()
        let mouse = RecordingMousePoster()
        let provider = FakeAXRectProvider()
        provider.setRect(CGRect(x: 0, y: 0, width: 800, height: 600), for: 100)
        let tracker = WindowRectTracker(provider: provider)
        await tracker.refresh(pid: 100)

        let player = ActionStreamPlayer(
            keyPoster: key,
            mousePoster: mouse,
            sleeper: RecordingSleeper(),
            tracker: tracker
        )

        // Drop the tracker entry — simulates the window closing mid-stream.
        await tracker.forget(pid: 100)

        let actions: [AutoKeysAction] = [
            .keyDown(keyCode: 13, modifiers: 0, dt: 0),
            .mouseMove(rel: CGPoint(x: 10, y: 10), dt: 0.016),
        ]

        let outcome = await player.play(
            actions: actions,
            targetPid: 100,
            focusGuard: { true }
        )

        XCTAssertEqual(outcome, .targetGone)
        // No mouse events posted — the rect lookup failed before the
        // first mouseMove translation.
        XCTAssertTrue(mouse.snapshot().isEmpty)
        // No held keys at the point of abort — keyDown never fired
        // because the rect lookup happens before any post.
        XCTAssertTrue(key.snapshot().isEmpty)
    }

    // MARK: - Focus theft mid-stream

    func testPlay_FocusGuardReturnsFalse_AbortsWithFocusStolen() async {
        let key = RecordingKeyPoster()
        let tracker = await makeTracker(for: 100, at: CGRect(x: 0, y: 0, width: 800, height: 600))

        let player = ActionStreamPlayer(
            keyPoster: key,
            mousePoster: RecordingMousePoster(),
            sleeper: RecordingSleeper(),
            tracker: tracker
        )

        // Guard returns false on the second invocation. Player matches
        // the legacy cycler's post-then-check semantics: the action that
        // just fired still lands; the abort kicks in BEFORE the next
        // action's post. Both held keys get released LIFO at cleanup.
        let callCount = LockedInt()
        let guardClosure: @Sendable () async -> Bool = {
            callCount.increment()
            return callCount.value < 2
        }

        let actions: [AutoKeysAction] = [
            .keyDown(keyCode: 13, modifiers: 0, dt: 0),
            .keyDown(keyCode: 49, modifiers: 0, dt: 0.020),
            .keyDown(keyCode: 0, modifiers: 0, dt: 0.020),  // never fires
        ]

        let outcome = await player.play(
            actions: actions,
            targetPid: 100,
            focusGuard: guardClosure
        )

        XCTAssertEqual(outcome, .focusStolen)

        // Actions 1 & 2 posted (post-then-check). Action 3 never fires.
        // Cleanup releases both held keys LIFO (most recent first).
        XCTAssertEqual(key.snapshot(), [
            .down(13, 0),
            .down(49, 0),
            .up(49, 0),
            .up(13, 0),
        ])
    }

    // MARK: - Cancellation cleanup

    func testPlay_CancelledMidStream_EmitsBalancingKeyUpForHeldKey() async {
        let key = RecordingKeyPoster()
        let tracker = await makeTracker(for: 100, at: CGRect(x: 0, y: 0, width: 800, height: 600))

        // Real-time sleeper so action 2's long dt actually suspends the
        // player and the cancellation can land mid-sleep.
        let player = ActionStreamPlayer(
            keyPoster: key,
            mousePoster: RecordingMousePoster(),
            sleeper: RealTimeSleeper(),
            tracker: tracker
        )

        let actions: [AutoKeysAction] = [
            .keyDown(keyCode: 13, modifiers: 0, dt: 0),
            .keyDown(keyCode: 49, modifiers: 0, dt: 10),  // long sleep
            .keyDown(keyCode: 0, modifiers: 0, dt: 10),
        ]

        let task = Task<ActionStreamPlayer.Outcome, Never> {
            await player.play(
                actions: actions,
                targetPid: 100,
                focusGuard: { true }
            )
        }

        // Wait until the first keyDown has posted and the player is in
        // action 2's long dt sleep before cancellation.
        await waitFor { key.snapshot().contains(.down(13, 0)) }

        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)

        let events = key.snapshot()
        // First keyDown landed before the long sleep that got cancelled.
        XCTAssertTrue(events.contains(.down(13, 0)), "first keyDown missing: \(events)")
        // Cleanup released the held key.
        XCTAssertTrue(events.contains(.up(13, 0)), "cancellation didn't release held key: \(events)")
        // Second keyDown never fired — cancellation landed during the
        // dt sleep, before any post.
        XCTAssertFalse(events.contains(.down(49, 0)), "second keyDown leaked past cancellation: \(events)")
    }

    // MARK: - Helpers

    private func waitFor(
        _ condition: @Sendable () async -> Bool,
        timeout: TimeInterval = 2.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// Tiny helper for thread-safe counter inside a `@Sendable` closure
/// captured by the player test.
private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); _value += 1; lock.unlock()
    }
}
