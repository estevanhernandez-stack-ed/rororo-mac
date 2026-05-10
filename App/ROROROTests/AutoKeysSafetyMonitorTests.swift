// AutoKeysSafetyMonitorTests.swift
// Drives the safety monitor with a fake `EventTapping` so we can inject
// arbitrary mouse / key events and assert what the monitor emits to its
// `observe()` stream. Production NSEvent wiring + Input Monitoring TCC
// are out of scope here; the integration test (item #12 / wave 4) covers
// the production path.

import XCTest
import CoreGraphics
@testable import RORORO

/// D-2 fake — drives focus-theft event delivery into the safety monitor
/// without going through AppKit's notification system. Module-internal
/// so AutoKeysCyclerTests can use it too.
final class FakeWorkspaceActivationObserver: WorkspaceActivationObserver, @unchecked Sendable {
    let lock = NSLock()
    private var handler: (@Sendable (pid_t) -> Void)?

    func observe(_ handler: @escaping @Sendable (pid_t) -> Void) -> WorkspaceActivationCancellable {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        return WorkspaceActivationCancellable { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.handler = nil
        }
    }

    /// Synthesize an "app became frontmost" event with the given pid.
    func fire(pid: pid_t) {
        lock.lock()
        let h = handler
        lock.unlock()
        h?(pid)
    }
}

/// Module-internal so AutoKeysCyclerTests can drive the safety integration
/// with synthesized events too.
final class FakeEventTapping: EventTapping, @unchecked Sendable {
    let lock = NSLock()
    private var continuation: AsyncStream<TappedEvent>.Continuation?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() -> AsyncStream<TappedEvent> {
        lock.lock()
        startCount += 1
        lock.unlock()
        return AsyncStream { c in
            self.lock.lock()
            self.continuation = c
            self.lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        stopCount += 1
        continuation?.finish()
        continuation = nil
        lock.unlock()
    }

    func send(_ event: TappedEvent) {
        lock.lock()
        let c = continuation
        lock.unlock()
        c?.yield(event)
    }
}

final class AutoKeysSafetyMonitorTests: XCTestCase {

    // MARK: - Helpers

    private func collect(
        _ stream: AsyncStream<EngagementEvent>,
        count: Int,
        timeout: TimeInterval = 2.0
    ) async -> [EngagementEvent] {
        var collected: [EngagementEvent] = []
        let deadline = Date().addingTimeInterval(timeout)
        var iterator = stream.makeAsyncIterator()
        while collected.count < count, Date() < deadline {
            if let event = await iterator.next() {
                collected.append(event)
            }
        }
        return collected
    }

    // MARK: - Tests

    func testStart_BeginsTappingAndStopReleases() async {
        let tapping = FakeEventTapping()
        let monitor = AutoKeysSafetyMonitor(tapping: tapping)

        await monitor.start()
        XCTAssertEqual(tapping.startCount, 1)
        XCTAssertEqual(tapping.stopCount, 0)

        await monitor.stop()
        XCTAssertEqual(tapping.stopCount, 1)
    }

    func testMouseMoved_EmitsUserEngaged() async {
        let tapping = FakeEventTapping()
        let monitor = AutoKeysSafetyMonitor(tapping: tapping)
        await monitor.start()
        let stream = await monitor.observe()

        tapping.send(TappedEvent(kind: .mouseMoved, timestamp: Date(), isSelfTagged: false))

        let events = await collect(stream, count: 1)
        XCTAssertEqual(events, [.userEngaged])

        await monitor.stop()
    }

    func testKeyDown_EmitsUserEngaged() async {
        let tapping = FakeEventTapping()
        let monitor = AutoKeysSafetyMonitor(tapping: tapping)
        await monitor.start()
        let stream = await monitor.observe()

        // Some non-kill key.
        tapping.send(TappedEvent(kind: .keyDown(13), timestamp: Date(), isSelfTagged: false))

        let events = await collect(stream, count: 1)
        XCTAssertEqual(events, [.userEngaged])

        await monitor.stop()
    }

    func testSelfTaggedEvents_AreIgnored() async {
        let tapping = FakeEventTapping()
        let monitor = AutoKeysSafetyMonitor(tapping: tapping)
        await monitor.start()
        let stream = await monitor.observe()

        // Self-tagged keystroke (the cycler firing) — must NOT engage.
        tapping.send(TappedEvent(kind: .keyDown(49), timestamp: Date(), isSelfTagged: true))
        tapping.send(TappedEvent(kind: .keyUp(49), timestamp: Date(), isSelfTagged: true))

        // Then a non-tagged event so we have something to wait for.
        tapping.send(TappedEvent(kind: .mouseMoved, timestamp: Date(), isSelfTagged: false))

        let events = await collect(stream, count: 1)
        XCTAssertEqual(events, [.userEngaged], "Self-tagged events should be filtered out")

        await monitor.stop()
    }

    func testHoldGesture_FiresKillAfterDeadline() async throws {
        let tapping = FakeEventTapping()
        let monitor = AutoKeysSafetyMonitor(
            tapping: tapping,
            config: AutoKeysSafetyConfig(
                killKeyCode: 80,
                gesture: .holdFor(seconds: 0.05),
                resumeGrace: 5
            )
        )
        await monitor.start()
        let stream = await monitor.observe()

        let now = Date()
        tapping.send(TappedEvent(kind: .keyDown(80), timestamp: now, isSelfTagged: false))

        // Kill-key keyDown no longer broadcasts `.userEngaged` (wave 3c
        // bug fix — was causing a race where the first tap of a
        // double-tap triggered an engagement pause that swallowed the
        // second tap's kill-toggle effect). Now: only `.killRequested`
        // fires, after the hold deadline.
        let events = await collect(stream, count: 1, timeout: 1.0)
        XCTAssertEqual(events, [.killRequested])

        await monitor.stop()
    }

    func testHoldGesture_KeyUpBeforeDeadline_DoesNotFireKill() async throws {
        let tapping = FakeEventTapping()
        let monitor = AutoKeysSafetyMonitor(
            tapping: tapping,
            config: AutoKeysSafetyConfig(
                killKeyCode: 80,
                gesture: .holdFor(seconds: 0.5),
                resumeGrace: 5
            )
        )
        await monitor.start()
        let stream = await monitor.observe()

        tapping.send(TappedEvent(kind: .keyDown(80), timestamp: Date(), isSelfTagged: false))
        // Release well before the 500ms deadline.
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        tapping.send(TappedEvent(kind: .keyUp(80), timestamp: Date(), isSelfTagged: false))

        // Wave 3c: kill-key keyDown no longer fires `.userEngaged`,
        // so we never expect any output from this gesture — keyUp
        // before the hold deadline cancels the hold timer cleanly.
        // Race the deadline + a buffer; if killRequested arrives, the
        // cancel didn't take.
        let waitDeadline = Date().addingTimeInterval(0.7)
        while Date() < waitDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // Send a mouseMoved as a sentinel; the next event yielded
        // must be that sentinel, not a stray kill.
        tapping.send(TappedEvent(kind: .mouseMoved, timestamp: Date(), isSelfTagged: false))
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .userEngaged, "Sentinel mouseMoved should be the first event since kill-key was released early.")

        await monitor.stop()
    }

    func testDoubleTapGesture_FiresKillOnSecondTapWithinWindow() async throws {
        let tapping = FakeEventTapping()
        let monitor = AutoKeysSafetyMonitor(
            tapping: tapping,
            config: AutoKeysSafetyConfig(
                killKeyCode: 80,
                gesture: .doubleTap(withinSeconds: 0.6),
                resumeGrace: 5
            )
        )
        await monitor.start()
        let stream = await monitor.observe()

        let t0 = Date()
        tapping.send(TappedEvent(kind: .keyDown(80), timestamp: t0, isSelfTagged: false))
        tapping.send(TappedEvent(kind: .keyDown(80), timestamp: t0.addingTimeInterval(0.2), isSelfTagged: false))

        // Wave 3c: kill-key keyDowns don't fire `.userEngaged`. The
        // second tap completes the double-tap → only `.killRequested`.
        let events = await collect(stream, count: 1, timeout: 1.0)
        XCTAssertEqual(events, [.killRequested])

        await monitor.stop()
    }

    func testDoubleTapGesture_SecondTapOutsideWindow_DoesNotFire() async throws {
        let tapping = FakeEventTapping()
        let monitor = AutoKeysSafetyMonitor(
            tapping: tapping,
            config: AutoKeysSafetyConfig(
                killKeyCode: 80,
                gesture: .doubleTap(withinSeconds: 0.1),
                resumeGrace: 5
            )
        )
        await monitor.start()
        let stream = await monitor.observe()

        let t0 = Date()
        tapping.send(TappedEvent(kind: .keyDown(80), timestamp: t0, isSelfTagged: false))
        // Second tap arrives 200ms later — outside the 100ms window.
        tapping.send(TappedEvent(kind: .keyDown(80), timestamp: t0.addingTimeInterval(0.2), isSelfTagged: false))

        // Wave 3c: kill-key keyDowns no longer fire `.userEngaged`,
        // and the second tap is outside the double-tap window so no
        // `.killRequested` either. Send a sentinel and verify nothing
        // fired before it.
        try await Task.sleep(nanoseconds: 200_000_000)
        tapping.send(TappedEvent(kind: .mouseMoved, timestamp: Date(), isSelfTagged: false))
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .userEngaged, "Only the sentinel mouseMoved should appear; the kill-key taps should have produced nothing.")

        await monitor.stop()
    }

    // MARK: - D-2 focus-theft tests

    func testActivation_UntrackedPidNotOwnPid_BroadcastsFocusStolen() async throws {
        let tapping = FakeEventTapping()
        let provider = FakeAXRectProvider()
        provider.setRect(CGRect(x: 0, y: 0, width: 10, height: 10), for: 100)
        let tracker = WindowRectTracker(provider: provider)
        await tracker.refresh(pid: 100)
        let activation = FakeWorkspaceActivationObserver()
        let monitor = AutoKeysSafetyMonitor(
            tapping: tapping,
            tracker: tracker,
            activationObserver: activation
        )
        await monitor.start()
        let stream = await monitor.observe()

        // Pid 999 is neither RORORO (whatever getpid() is in test) nor
        // tracked (100 is the only tracked pid). Should broadcast.
        activation.fire(pid: 999)

        let events = await collect(stream, count: 1, timeout: 1.0)
        XCTAssertEqual(events, [.focusStolen(byPid: 999)])

        await monitor.stop()
    }

    func testActivation_TrackedPid_DoesNotBroadcast() async throws {
        let tapping = FakeEventTapping()
        let provider = FakeAXRectProvider()
        provider.setRect(CGRect(x: 0, y: 0, width: 10, height: 10), for: 100)
        let tracker = WindowRectTracker(provider: provider)
        await tracker.refresh(pid: 100)
        let activation = FakeWorkspaceActivationObserver()
        let monitor = AutoKeysSafetyMonitor(
            tapping: tapping,
            tracker: tracker,
            activationObserver: activation
        )
        await monitor.start()
        let stream = await monitor.observe()

        // Pid 100 IS tracked — moving focus between Roblox windows is
        // normal during a cycle. Should NOT broadcast.
        activation.fire(pid: 100)

        // Sentinel: send a mouseMoved (with no tracker rect at the
        // current cursor position; this test doesn't control cursor
        // location) to confirm focusStolen wasn't queued.
        try await Task.sleep(nanoseconds: 100_000_000)
        tapping.send(TappedEvent(kind: .mouseMoved, timestamp: Date(), isSelfTagged: false))
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        // First event should be the sentinel mouseMoved → userEngaged
        // (unless the cursor happens to be inside the dummy 10x10 rect
        // at 0,0 which is virtually impossible). NOT focusStolen.
        XCTAssertNotEqual(first, .focusStolen(byPid: 100), "Activation of tracked pid must not broadcast focusStolen")

        await monitor.stop()
    }

    func testActivation_OwnPid_DoesNotBroadcast() async throws {
        let tapping = FakeEventTapping()
        let provider = FakeAXRectProvider()
        let tracker = WindowRectTracker(provider: provider)
        let activation = FakeWorkspaceActivationObserver()
        let monitor = AutoKeysSafetyMonitor(
            tapping: tapping,
            tracker: tracker,
            activationObserver: activation
        )
        await monitor.start()
        let stream = await monitor.observe()

        // Fire activation with our own pid — must be ignored.
        activation.fire(pid: getpid())

        // Sentinel.
        try await Task.sleep(nanoseconds: 100_000_000)
        tapping.send(TappedEvent(kind: .mouseMoved, timestamp: Date(), isSelfTagged: false))
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .userEngaged, "Own-pid activation must not broadcast focusStolen; sentinel mouseMoved should be first event")

        await monitor.stop()
    }

    func testStop_CancelsActivationObserver() async {
        let tapping = FakeEventTapping()
        let activation = FakeWorkspaceActivationObserver()
        let monitor = AutoKeysSafetyMonitor(
            tapping: tapping,
            activationObserver: activation
        )

        await monitor.start()
        await monitor.stop()

        // After stop, firing the activation observer should be a no-op
        // (handler was nilled by the cancellable). We can't easily
        // observe "no event" without a timeout, so just verify no crash.
        activation.fire(pid: 999)
    }
}
