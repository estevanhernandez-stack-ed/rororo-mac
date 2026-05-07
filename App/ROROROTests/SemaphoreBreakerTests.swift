// SemaphoreBreakerTests.swift

import XCTest
@testable import RORORO

final class SemaphoreBreakerTests: XCTestCase {

    func testUnlinkOnNonexistentNameReturnsAlreadyUnlinked() {
        // macOS PSEMNAMLEN caps semaphore names at 31 bytes (incl. NUL).
        // `/rt-XXXX` is 8 bytes, well under the cap.
        let randomName = "/rt-\(UUID().uuidString.prefix(4))"
        let outcome = SemaphoreBreaker.unlink(name: String(randomName))
        XCTAssertEqual(outcome, .alreadyUnlinked)
    }

    func testBreakRobloxSingletonReturnsTerminalState() {
        // We can't pre-create /RobloxPlayerUniq from tests without
        // permission risk, so just assert the call returns a non-failure
        // outcome (either .unlinked if Roblox happened to be running, or
        // .alreadyUnlinked otherwise). This is the state the caller will
        // act on in production — a failed() outcome would be the bug.
        let outcome = SemaphoreBreaker.breakRobloxSingleton()
        switch outcome {
        case .unlinked, .alreadyUnlinked:
            // Both are correct end states for the technique.
            break
        case .failed(let errno, let description):
            XCTFail("Unexpected sem_unlink failure: errno=\(errno) (\(description))")
        }
    }

    func testCanonicalSemaphoreNameIsRobloxPlayerUniq() {
        // This is the contract documented in Insadem's public-source
        // technique. If macOS Roblox ever renames the semaphore, this
        // test stays passing (asserting our constant) but the
        // breakRobloxSingleton path silently goes no-op in production —
        // surface via diagnostics, not via this test.
        XCTAssertEqual(SemaphoreBreaker.robloxSingletonSemaphoreName, "/RobloxPlayerUniq")
    }
}
