// WindowRectTrackerTests.swift
// Exercises the rect cache + lookup behavior with a fake AX provider.
// Production `AXUIElementRectProvider` is exercised only by manual smoke;
// AX calls aren't fakeable without taking over the whole AX subsystem.

import XCTest
import CoreGraphics
@testable import RORORO

/// Module-internal fake — `AutoKeysCyclerTests` reaches for this too when
/// driving the rect-aware safety integration.
final class FakeAXRectProvider: AXRectProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var rectsByPid: [pid_t: CGRect] = [:]
    private(set) var callCount = 0

    func setRect(_ rect: CGRect?, for pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        if let rect {
            rectsByPid[pid] = rect
        } else {
            rectsByPid.removeValue(forKey: pid)
        }
    }

    func focusedWindowRect(pid: pid_t) -> CGRect? {
        lock.lock(); defer { lock.unlock() }
        callCount += 1
        return rectsByPid[pid]
    }
}

final class WindowRectTrackerTests: XCTestCase {

    func testRefresh_PopulatesCacheFromProvider() async {
        let provider = FakeAXRectProvider()
        provider.setRect(CGRect(x: 100, y: 200, width: 800, height: 600), for: 42)
        let tracker = WindowRectTracker(provider: provider)

        await tracker.refresh(pid: 42)

        let rect = await tracker.rect(for: 42)
        XCTAssertEqual(rect, CGRect(x: 100, y: 200, width: 800, height: 600))
    }

    func testRefresh_DropsPidWhenProviderReturnsNil() async {
        let provider = FakeAXRectProvider()
        provider.setRect(CGRect(x: 0, y: 0, width: 100, height: 100), for: 42)
        let tracker = WindowRectTracker(provider: provider)
        await tracker.refresh(pid: 42)
        let initial = await tracker.rect(for: 42)
        XCTAssertNotNil(initial)

        // Window now minimized / app gone — provider returns nil.
        provider.setRect(nil, for: 42)
        await tracker.refresh(pid: 42)

        let after = await tracker.rect(for: 42)
        XCTAssertNil(after)
    }

    func testContains_ReturnsPidWhenPointInsideRect() async {
        let provider = FakeAXRectProvider()
        provider.setRect(CGRect(x: 100, y: 100, width: 200, height: 200), for: 42)
        let tracker = WindowRectTracker(provider: provider)
        await tracker.refresh(pid: 42)

        let pid = await tracker.contains(point: CGPoint(x: 150, y: 150))
        XCTAssertEqual(pid, 42)
    }

    func testContains_ReturnsNilForPointOutsideAllRects() async {
        let provider = FakeAXRectProvider()
        provider.setRect(CGRect(x: 100, y: 100, width: 200, height: 200), for: 42)
        let tracker = WindowRectTracker(provider: provider)
        await tracker.refresh(pid: 42)

        let pid = await tracker.contains(point: CGPoint(x: 500, y: 500))
        XCTAssertNil(pid)
    }

    func testContains_MultipleRectsReturnsContainingPid() async {
        let provider = FakeAXRectProvider()
        provider.setRect(CGRect(x: 0, y: 0, width: 100, height: 100), for: 1)
        provider.setRect(CGRect(x: 200, y: 200, width: 100, height: 100), for: 2)
        let tracker = WindowRectTracker(provider: provider)
        await tracker.refresh(pid: 1)
        await tracker.refresh(pid: 2)

        let first = await tracker.contains(point: CGPoint(x: 50, y: 50))
        let second = await tracker.contains(point: CGPoint(x: 250, y: 250))
        let gap = await tracker.contains(point: CGPoint(x: 150, y: 150))
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertNil(gap)
    }

    func testCurrentPids_ReturnsAllTrackedPids() async {
        let provider = FakeAXRectProvider()
        provider.setRect(CGRect(x: 0, y: 0, width: 10, height: 10), for: 1)
        provider.setRect(CGRect(x: 0, y: 0, width: 10, height: 10), for: 2)
        provider.setRect(CGRect(x: 0, y: 0, width: 10, height: 10), for: 3)
        let tracker = WindowRectTracker(provider: provider)
        await tracker.refresh(pid: 1)
        await tracker.refresh(pid: 2)
        await tracker.refresh(pid: 3)

        let pids = Set(await tracker.currentPids())
        XCTAssertEqual(pids, [1, 2, 3])
    }

    func testForget_RemovesEntry() async {
        let provider = FakeAXRectProvider()
        provider.setRect(CGRect(x: 0, y: 0, width: 10, height: 10), for: 42)
        let tracker = WindowRectTracker(provider: provider)
        await tracker.refresh(pid: 42)
        let initial = await tracker.rect(for: 42)
        XCTAssertNotNil(initial)

        await tracker.forget(pid: 42)

        let after = await tracker.rect(for: 42)
        let pids = await tracker.currentPids()
        XCTAssertNil(after)
        XCTAssertTrue(pids.isEmpty)
    }

    func testReset_ClearsAll() async {
        let provider = FakeAXRectProvider()
        provider.setRect(CGRect(x: 0, y: 0, width: 10, height: 10), for: 1)
        provider.setRect(CGRect(x: 0, y: 0, width: 10, height: 10), for: 2)
        let tracker = WindowRectTracker(provider: provider)
        await tracker.refresh(pid: 1)
        await tracker.refresh(pid: 2)

        await tracker.reset()

        let pids = await tracker.currentPids()
        let r1 = await tracker.rect(for: 1)
        let r2 = await tracker.rect(for: 2)
        XCTAssertTrue(pids.isEmpty)
        XCTAssertNil(r1)
        XCTAssertNil(r2)
    }

    func testContains_EmptyTrackerReturnsNil() async {
        let provider = FakeAXRectProvider()
        let tracker = WindowRectTracker(provider: provider)

        let hit = await tracker.contains(point: CGPoint(x: 0, y: 0))
        let pids = await tracker.currentPids()
        XCTAssertNil(hit)
        XCTAssertTrue(pids.isEmpty)
    }
}
