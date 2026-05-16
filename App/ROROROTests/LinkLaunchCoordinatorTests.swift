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
