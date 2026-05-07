// URLProtocolStub.swift
// Test fixture — intercepts URLSession traffic so RobloxApi tests can
// drive the CSRF dance + error paths without touching the network.
//
// Usage:
//   override func setUp() {
//       let config = URLSessionConfiguration.ephemeral
//       config.protocolClasses = [URLProtocolStub.self]
//       RobloxApi.urlSessionForTesting = URLSession(configuration: config)
//       URLProtocolStub.reset()
//   }
//   override func tearDown() {
//       URLProtocolStub.reset()
//       RobloxApi.urlSessionForTesting = nil
//   }
//
//   // In test:
//   URLProtocolStub.enqueue(status: 403, headers: ["x-csrf-token": "abc"])
//   URLProtocolStub.enqueue(status: 200, headers: ["RBX-Authentication-Ticket": "TKT"])

import Foundation

final class URLProtocolStub: URLProtocol {

    typealias ResponseTuple = (response: HTTPURLResponse, body: Data?)

    nonisolated(unsafe) static var responses: [ResponseTuple] = []
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    nonisolated(unsafe) static var capturedBodies: [Data] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        responses.removeAll()
        capturedRequests.removeAll()
        capturedBodies.removeAll()
    }

    static func enqueue(
        status: Int,
        headers: [String: String] = [:],
        body: Data? = nil,
        url: URL = URL(string: "https://stub.invalid/")!
    ) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        lock.lock(); defer { lock.unlock() }
        responses.append((response, body))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        URLProtocolStub.lock.lock()
        URLProtocolStub.capturedRequests.append(request)
        URLProtocolStub.capturedBodies.append(Self.collectBody(from: request))
        let next: ResponseTuple?
        if URLProtocolStub.responses.isEmpty {
            next = nil
        } else {
            next = URLProtocolStub.responses.removeFirst()
        }
        URLProtocolStub.lock.unlock()

        guard let (response, body) = next else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func collectBody(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
