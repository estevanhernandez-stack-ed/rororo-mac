// RobloxUpdateDriverTests.swift
// State-machine coverage for the graceful-update path: when the gate
// says /Applications/Roblox.app is stale, the driver opens the canonical
// player (which self-updates), waits for version parity, dismisses the
// relaunched player, and reports an outcome the UI can retry on.
// Every side effect is injected so no Roblox is needed.

import XCTest
@testable import RORORO

final class RobloxUpdateDriverTests: XCTestCase {

    /// Thread-safe mutable box for the fake local version + call counts.
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var _local: String?
        private var _localReadsUntilFlip: Int
        private var _flipTo: String?
        private(set) var openCalls = 0
        private(set) var terminateCalls = 0
        private(set) var sleeps: [TimeInterval] = []

        init(local: String?, flipTo: String? = nil, afterReads: Int = 0) {
            _local = local
            _flipTo = flipTo
            _localReadsUntilFlip = afterReads
        }

        func localVersion() -> String? {
            lock.lock(); defer { lock.unlock() }
            if let flipTo = _flipTo {
                if _localReadsUntilFlip <= 0 {
                    _local = flipTo
                } else {
                    _localReadsUntilFlip -= 1
                }
            }
            return _local
        }
        func open() { lock.lock(); openCalls += 1; lock.unlock() }
        func terminate() -> Int { lock.lock(); terminateCalls += 1; lock.unlock(); return 1 }
        func sleep(_ s: TimeInterval) { lock.lock(); sleeps.append(s); lock.unlock() }
    }

    private struct FakeSleeper: Sleeper {
        let probe: Probe
        func sleep(seconds: TimeInterval) async throws {
            probe.sleep(seconds)
            // Yield so concurrent callers in the join test can overlap.
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func makeDriver(
        probe: Probe,
        live: String?,
        timeout: TimeInterval = 180,
        pollInterval: TimeInterval = 2
    ) -> RobloxUpdateDriver {
        let deps = RobloxUpdateDriver.Dependencies(
            localVersion: { probe.localVersion() },
            liveVersion: { live },
            openRoblox: { probe.open() },
            terminateCanonicalPlayer: { probe.terminate() },
            sleeper: FakeSleeper(probe: probe)
        )
        return RobloxUpdateDriver(
            dependencies: deps,
            timeout: timeout,
            pollInterval: pollInterval,
            playerSettleGrace: 0
        )
    }

    func testRun_AlreadyCurrent_DoesNotOpenRoblox() async {
        let probe = Probe(local: "0.738.0.7381393")
        let driver = makeDriver(probe: probe, live: "0.738.0.7381393")
        let outcome = await driver.run()
        XCTAssertEqual(outcome, .alreadyCurrent)
        XCTAssertEqual(probe.openCalls, 0)
        XCTAssertEqual(probe.terminateCalls, 0)
    }

    func testRun_LiveUnknown_DoesNotOpenRoblox() async {
        let probe = Probe(local: "0.726.0.7261140")
        let driver = makeDriver(probe: probe, live: nil)
        let outcome = await driver.run()
        XCTAssertEqual(outcome, .liveUnknown)
        XCTAssertEqual(probe.openCalls, 0)
    }

    func testRun_VersionFlips_ReportsUpdatedAndDismissesPlayer() async {
        // Local reads "old" for the first 3 polls, then "new".
        let probe = Probe(local: "0.726.0.7261140", flipTo: "0.738.0.7381393", afterReads: 3)
        let driver = makeDriver(probe: probe, live: "0.738.0.7381393")
        let outcome = await driver.run()
        XCTAssertEqual(outcome, .updated(to: "0.738.0.7381393"))
        XCTAssertEqual(probe.openCalls, 1, "open the canonical player exactly once")
        XCTAssertGreaterThanOrEqual(probe.terminateCalls, 1, "dismiss the relaunched player")
    }

    func testRun_NeverReachesParity_TimesOut() async {
        let probe = Probe(local: "0.726.0.7261140")
        let driver = makeDriver(probe: probe, live: "0.738.0.7381393", timeout: 10, pollInterval: 2)
        let outcome = await driver.run()
        XCTAssertEqual(outcome, .timedOut(local: "0.726.0.7261140", live: "0.738.0.7381393"))
        XCTAssertEqual(probe.openCalls, 1)
        XCTAssertEqual(probe.terminateCalls, 0, "don't kill anything on timeout")
        XCTAssertGreaterThanOrEqual(probe.sleeps.count, 5, "polled up to the deadline")
    }

    func testRun_ConcurrentCallers_ShareOneRun() async {
        let probe = Probe(local: "0.726.0.7261140", flipTo: "0.738.0.7381393", afterReads: 5)
        let driver = makeDriver(probe: probe, live: "0.738.0.7381393")
        async let a = driver.run()
        async let b = driver.run()
        let (oa, ob) = await (a, b)
        XCTAssertEqual(oa, .updated(to: "0.738.0.7381393"))
        XCTAssertEqual(ob, oa)
        XCTAssertEqual(probe.openCalls, 1, "second caller joins the in-flight run")
    }

    func testRun_AfterCompletion_CanRunAgain() async {
        let probe = Probe(local: "0.726.0.7261140", flipTo: "0.738.0.7381393", afterReads: 1)
        let driver = makeDriver(probe: probe, live: "0.738.0.7381393")
        _ = await driver.run()
        let second = await driver.run()
        XCTAssertEqual(second, .alreadyCurrent, "a fresh run after completion re-evaluates")
    }

    func testOutcome_UserMessages() {
        XCTAssertNil(RobloxUpdateDriver.Outcome.updated(to: "x").failureMessage)
        XCTAssertNil(RobloxUpdateDriver.Outcome.alreadyCurrent.failureMessage)
        let t = RobloxUpdateDriver.Outcome.timedOut(local: "0.726.0.7261140", live: "0.738.0.7381393").failureMessage
        XCTAssertNotNil(t)
        XCTAssertTrue(t!.contains("0.738.0.7381393"))
        XCTAssertNotNil(RobloxUpdateDriver.Outcome.liveUnknown.failureMessage)
        XCTAssertNotNil(RobloxUpdateDriver.Outcome.openFailed(reason: "boom").failureMessage)
    }
}
