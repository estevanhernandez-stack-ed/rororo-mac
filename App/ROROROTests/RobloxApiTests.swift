// RobloxApiTests.swift
// Stubbed-HTTP coverage of the auth-ticket CSRF dance + key error paths.
// Live-Roblox calls are out of scope (manual smoke before each release).
// Includes the 415 regression guard for the Content-Type contract caught
// at spike-time per RORORO Windows spec §5.7.

import XCTest
@testable import RORORO

final class RobloxApiTests: XCTestCase {

    private let testCookie = "FAKE_COOKIE_FOR_TESTS_ONLY"

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        RobloxApi.urlSessionForTesting = URLSession(configuration: config)
        URLProtocolStub.reset()
    }

    override func tearDown() {
        URLProtocolStub.reset()
        RobloxApi.urlSessionForTesting = nil
        super.tearDown()
    }

    // MARK: - Happy path

    func testGetAuthTicket_HappyPath_ReturnsTicketAfterCsrfDance() async throws {
        URLProtocolStub.enqueue(status: 403, headers: ["x-csrf-token": "csrf-abc-123"])
        URLProtocolStub.enqueue(status: 200, headers: ["RBX-Authentication-Ticket": "TICKET-XYZ"])

        let ticket = try await RobloxApi.getAuthTicket(cookie: testCookie)

        XCTAssertEqual(ticket.ticket, "TICKET-XYZ")
        XCTAssertGreaterThan(ticket.capturedAt.timeIntervalSinceNow, -60)
        XCTAssertEqual(URLProtocolStub.capturedRequests.count, 2)
    }

    // MARK: - Header / Cookie / Referer / Content-Type

    func testGetAuthTicket_BothPostsSendContentTypeApplicationJson() async throws {
        URLProtocolStub.enqueue(status: 403, headers: ["x-csrf-token": "t"])
        URLProtocolStub.enqueue(status: 200, headers: ["RBX-Authentication-Ticket": "T"])

        _ = try await RobloxApi.getAuthTicket(cookie: testCookie)

        for request in URLProtocolStub.capturedRequests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        }
    }

    func testGetAuthTicket_BothPostsSendCookieAndReferer() async throws {
        URLProtocolStub.enqueue(status: 403, headers: ["x-csrf-token": "t"])
        URLProtocolStub.enqueue(status: 200, headers: ["RBX-Authentication-Ticket": "T"])

        _ = try await RobloxApi.getAuthTicket(cookie: testCookie)

        for request in URLProtocolStub.capturedRequests {
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Cookie"),
                ".ROBLOSECURITY=\(testCookie)"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://www.roblox.com/")
        }
    }

    func testGetAuthTicket_SecondPostHasCsrfToken_FirstDoesNot() async throws {
        URLProtocolStub.enqueue(status: 403, headers: ["x-csrf-token": "csrf-token-value"])
        URLProtocolStub.enqueue(status: 200, headers: ["RBX-Authentication-Ticket": "T"])

        _ = try await RobloxApi.getAuthTicket(cookie: testCookie)

        XCTAssertNil(URLProtocolStub.capturedRequests[0].value(forHTTPHeaderField: "X-CSRF-TOKEN"))
        XCTAssertEqual(
            URLProtocolStub.capturedRequests[1].value(forHTTPHeaderField: "X-CSRF-TOKEN"),
            "csrf-token-value"
        )
    }

    // MARK: - Cookie expired

    func testGetAuthTicket_401OnFirstPost_ThrowsCookieExpired() async {
        URLProtocolStub.enqueue(status: 401)

        await assertThrows(RobloxApi.APIError.cookieExpired) {
            _ = try await RobloxApi.getAuthTicket(cookie: testCookie)
        }
    }

    func testGetAuthTicket_401OnSecondPost_ThrowsCookieExpired() async {
        URLProtocolStub.enqueue(status: 403, headers: ["x-csrf-token": "t"])
        URLProtocolStub.enqueue(status: 401)

        await assertThrows(RobloxApi.APIError.cookieExpired) {
            _ = try await RobloxApi.getAuthTicket(cookie: testCookie)
        }
    }

    // MARK: - 415 Content-Type guard

    func testGetAuthTicket_415_ThrowsHelpfulContentTypeMessage() async {
        URLProtocolStub.enqueue(status: 415)

        do {
            _ = try await RobloxApi.getAuthTicket(cookie: testCookie)
            XCTFail("Expected APIError.unexpected")
        } catch let RobloxApi.APIError.unexpected(status, message) {
            XCTAssertEqual(status, 415)
            XCTAssertTrue(message.contains("Content-Type"), "expected hint about Content-Type, got: \(message)")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Transient

    func testGetAuthTicket_500OnFirstPost_ThrowsTransient() async {
        URLProtocolStub.enqueue(status: 500)

        do {
            _ = try await RobloxApi.getAuthTicket(cookie: testCookie)
            XCTFail("Expected APIError.transient")
        } catch let RobloxApi.APIError.transient(status) {
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Missing headers

    func testGetAuthTicket_NoCsrfTokenHeader_ThrowsUnexpected() async {
        URLProtocolStub.enqueue(status: 403)

        do {
            _ = try await RobloxApi.getAuthTicket(cookie: testCookie)
            XCTFail("Expected APIError.unexpected")
        } catch let RobloxApi.APIError.unexpected(_, message) {
            XCTAssertTrue(message.contains("X-CSRF-TOKEN"), "got: \(message)")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testGetAuthTicket_NoTicketHeader_ThrowsUnexpected() async {
        URLProtocolStub.enqueue(status: 403, headers: ["x-csrf-token": "t"])
        URLProtocolStub.enqueue(status: 200)

        do {
            _ = try await RobloxApi.getAuthTicket(cookie: testCookie)
            XCTFail("Expected APIError.unexpected")
        } catch let RobloxApi.APIError.unexpected(_, message) {
            XCTAssertTrue(message.contains("RBX-Authentication-Ticket"), "got: \(message)")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Header casing

    func testGetAuthTicket_TicketHeaderCasing_InsensitiveLookup() async throws {
        URLProtocolStub.enqueue(status: 403, headers: ["X-CSRF-Token": "t"])
        URLProtocolStub.enqueue(status: 200, headers: ["rbx-authentication-ticket": "T-LOWER"])

        let ticket = try await RobloxApi.getAuthTicket(cookie: testCookie)

        XCTAssertEqual(ticket.ticket, "T-LOWER")
    }

    // MARK: - Empty cookie rejection

    func testGetAuthTicket_RejectsEmptyCookie() async {
        do {
            _ = try await RobloxApi.getAuthTicket(cookie: "")
            XCTFail("Expected APIError.unexpected for empty cookie")
        } catch RobloxApi.APIError.unexpected {
            // ok
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Helpers

    private func assertThrows<E: Error & Equatable>(
        _ expected: E,
        _ block: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await block()
            XCTFail("Expected error \(expected)", file: file, line: line)
        } catch let actual as E {
            XCTAssertEqual(actual, expected, file: file, line: line)
        } catch {
            XCTFail("Wrong error type: \(error)", file: file, line: line)
        }
    }
}
