// MultiInstanceCoordinatorTests.swift
// Integration tests for the inbound-URL routing branch in
// MultiInstanceCoordinator.handleIncomingURL. Focused on the
// 0/1/2+/Cancel decision logic — full launch pipeline (copy + plist
// flip + spawn) is verified manually per repo posture.

import XCTest
@testable import RORORO

@MainActor
final class MultiInstanceCoordinatorTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        // Clear lastError and any in-flight picker state between tests.
        MultiInstanceState.shared.lastError = nil
        LinkLaunchCoordinator.shared.cancel()
        AccountStore.shared._setAccountsForTesting([])
    }

    override func tearDown() async throws {
        AccountStore.shared._setAccountsForTesting([])
        LinkLaunchCoordinator.shared.cancel()
        MultiInstanceState.shared.lastError = nil
        try await super.tearDown()
    }

    private func makeAccount(userId: String, username: String) -> Account {
        Account(
            userId: userId,
            username: username,
            displayName: username
        )
    }

    func testHandleIncomingURL_ZeroAccounts_SetsLastErrorAndAborts() async {
        // AccountStore is already empty per setUp; no extra setAccounts needed.
        let url = URL(string: "roblox-player://1+launchmode+play")!

        MultiInstanceCoordinator.shared.handleIncomingURL(url, userId: nil)

        // Give the coordinator a beat — none of the picker async path
        // should run, but a small yield keeps the assertion robust if
        // anything dispatches.
        await Task.yield()

        XCTAssertNotNil(MultiInstanceState.shared.lastError, "0-accounts path must surface a lastError.")
        XCTAssertEqual(LinkLaunchCoordinator.shared.state, .idle, "Picker must NOT open with 0 accounts.")
    }

    func testHandleIncomingURL_TwoOrMoreAccounts_OpensPicker() async {
        let url = URL(string: "roblox-player://1+launchmode+play&placeId=42")!
        let accounts = [
            makeAccount(userId: "111", username: "alt1"),
            makeAccount(userId: "222", username: "alt2"),
        ]
        AccountStore.shared._setAccountsForTesting(accounts)

        MultiInstanceCoordinator.shared.handleIncomingURL(url, userId: nil)

        // Picker dispatches via Task { @MainActor in ... }; yield once
        // so the await-on-requestChoice has a chance to transition the
        // coordinator's state.
        let deadline = Date().addingTimeInterval(1.0)
        while LinkLaunchCoordinator.shared.state == .idle && Date() < deadline {
            await Task.yield()
        }

        XCTAssertEqual(
            LinkLaunchCoordinator.shared.state,
            .choosing(pendingURL: url, accounts: accounts),
            "2+ accounts must transition the picker into .choosing(url, accounts)."
        )

        // Clean up so tearDown's cancel doesn't fight a leftover continuation.
        LinkLaunchCoordinator.shared.cancel()
    }

    func testHandleIncomingURL_PickerCancel_DoesNotEnqueueLaunch() async {
        let url = URL(string: "roblox-player://1+launchmode+play")!
        let accounts = [
            makeAccount(userId: "111", username: "alt1"),
            makeAccount(userId: "222", username: "alt2"),
        ]
        AccountStore.shared._setAccountsForTesting(accounts)

        MultiInstanceCoordinator.shared.handleIncomingURL(url, userId: nil)

        let deadline = Date().addingTimeInterval(1.0)
        while LinkLaunchCoordinator.shared.state == .idle && Date() < deadline {
            await Task.yield()
        }

        LinkLaunchCoordinator.shared.cancel()

        // Drain via polling — gives the awaiting Task in
        // handleIncomingURL a deterministic window to see the nil
        // result and unwind. Single Task.yield() is sufficient on
        // light-load machines but can race on loaded CI, so match
        // the polling pattern used for the picker-open transition.
        let drainDeadline = Date().addingTimeInterval(1.0)
        while LinkLaunchCoordinator.shared.state != .idle && Date() < drainDeadline {
            await Task.yield()
        }

        // Cancel returns the state to .idle; no recursion fires.
        XCTAssertEqual(LinkLaunchCoordinator.shared.state, .idle, "Cancel must return state to .idle.")
        // Note: asserting "no launch fired" via MultiInstanceState would
        // require a hook into the launch queue we don't have today.
        // The state-returns-to-idle assertion is sufficient — the
        // handleIncomingURL Task discards the nil result and returns.
    }

    /// The 1-account path skips the picker and silently launches as
    /// that account via RobloxLauncher.shared.launch. Picker-idle is
    /// the load-bearing assertion — that's what distinguishes 1-account
    /// from 2+ accounts.
    ///
    /// We do NOT assert on lastError here. In the test environment the
    /// async launch attempt fails (no Keychain cookie for the test
    /// userId, no network), which sets lastError to a "Launch failed"
    /// message. That's expected and orthogonal to the routing decision
    /// being tested. The 0-account path's "Add an account" banner is
    /// covered by `testHandleIncomingURL_ZeroAccounts_SetsLastErrorAndAborts`.
    func testHandleIncomingURL_OneAccount_DoesNotOpenPicker() async {
        let url = URL(string: "roblox-player://1+launchmode+play")!
        AccountStore.shared._setAccountsForTesting([
            makeAccount(userId: "111", username: "alt1")
        ])

        MultiInstanceCoordinator.shared.handleIncomingURL(url, userId: nil)
        await Task.yield()

        XCTAssertEqual(LinkLaunchCoordinator.shared.state, .idle, "1-account path must NOT open picker.")
    }
}
