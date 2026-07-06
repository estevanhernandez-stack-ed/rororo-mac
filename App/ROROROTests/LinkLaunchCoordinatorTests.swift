// LinkLaunchCoordinatorTests.swift
// Unit tests for the picker state machine. UI is separately verified
// via SwiftUI #Preview + manual smoke per repo posture.

import XCTest
@testable import RORORO

@MainActor
final class LinkLaunchCoordinatorTests: XCTestCase {

    private func makeAccount(userId: String, username: String) -> Account {
        Account(
            userId: userId,
            username: username,
            displayName: username,
            avatarThumbnailURL: nil,
            lastLaunchedAt: nil
        )
    }

    func testRequestChoice_SubmitResolvesWithUserId() async {
        let coord = LinkLaunchCoordinator()
        let url = URL(string: "roblox-player://1+launchmode+play")!
        let accounts = [
            makeAccount(userId: "111", username: "AltAcct1"),
            makeAccount(userId: "222", username: "AltAcct2"),
        ]

        let resultTask = Task { @MainActor in
            await coord.requestChoice(url: url, accounts: accounts)
        }

        // Wait for state to transition to .choosing.
        await waitFor { coord.state != .idle }
        XCTAssertEqual(coord.state, .choosing(pendingURL: url, accounts: accounts))

        coord.submit(userId: "222")
        let result = await resultTask.value
        XCTAssertEqual(result, "222")
        XCTAssertEqual(coord.state, .idle, "State must return to idle after submit.")
    }

    func testRequestChoice_NewerCallEvictsOlder() async {
        let coord = LinkLaunchCoordinator()
        let urlA = URL(string: "roblox-player://1+launchmode+play&placeId=A")!
        let urlB = URL(string: "roblox-player://1+launchmode+play&placeId=B")!
        let accounts = [
            makeAccount(userId: "111", username: "AltAcct1"),
            makeAccount(userId: "222", username: "AltAcct2"),
        ]

        let taskA = Task { @MainActor in
            await coord.requestChoice(url: urlA, accounts: accounts)
        }
        await waitFor { coord.state != .idle }
        XCTAssertEqual(coord.state, .choosing(pendingURL: urlA, accounts: accounts))

        let taskB = Task { @MainActor in
            await coord.requestChoice(url: urlB, accounts: accounts)
        }
        // After eviction the state should rebind to B's URL.
        await waitFor {
            if case .choosing(let pending, _) = coord.state, pending == urlB { return true }
            return false
        }

        coord.submit(userId: "222")

        let resultA = await taskA.value
        let resultB = await taskB.value
        XCTAssertNil(resultA, "Older requestChoice must resolve with nil when evicted.")
        XCTAssertEqual(resultB, "222", "Newer requestChoice must resolve with the submitted userId.")
        XCTAssertEqual(coord.state, .idle, "State must return to idle after submit.")
    }

    func testCancel_ResolvesWithNil() async {
        let coord = LinkLaunchCoordinator()
        let url = URL(string: "roblox-player://1+launchmode+play")!
        let accounts = [
            makeAccount(userId: "111", username: "AltAcct1"),
            makeAccount(userId: "222", username: "AltAcct2"),
        ]

        let resultTask = Task { @MainActor in
            await coord.requestChoice(url: url, accounts: accounts)
        }
        await waitFor { coord.state != .idle }
        XCTAssertEqual(
            coord.state,
            .choosing(pendingURL: url, accounts: accounts),
            "State must be .choosing(url, accounts) before cancel."
        )

        coord.cancel()

        let result = await resultTask.value
        XCTAssertNil(result, "cancel() must resolve the suspended requestChoice with nil.")
        XCTAssertEqual(coord.state, .idle, "State must return to idle after cancel.")
    }

    func testCancel_WhileIdle_IsNoOp() async {
        let coord = LinkLaunchCoordinator()
        coord.cancel() // Must not crash, must not change state.
        XCTAssertEqual(coord.state, .idle, "cancel() while idle must remain idle.")
    }

    /// Small polling helper — XCTestExpectation feels heavy for observing
    /// an @Published transition that happens within a few microseconds.
    private func waitFor(
        _ condition: @MainActor () -> Bool,
        timeout: TimeInterval = 1.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
        }
    }
}
