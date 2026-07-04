import Foundation
@testable import RocketChatSDK

/// Scripted transport: each queued step can assert on the outgoing request
/// and returns a canned response.
final class MockHTTPTransport: HTTPTransport, @unchecked Sendable {
    struct Step {
        let handler: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
    }

    private let lock = NSLock()
    private var steps: [Step] = []
    private(set) var requests: [URLRequest] = []

    func expect(
        _ handler: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
    ) {
        lock.lock()
        defer { lock.unlock() }
        steps.append(Step(handler: handler))
    }

    /// Queue a plain JSON response with optional status/headers.
    func respond(status: Int = 200, json: String, headers: [String: String] = [:]) {
        expect { request in
            (Data(json.utf8), MockHTTPTransport.httpResponse(
                url: request.url!, status: status, headers: headers))
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let step: Step? = lock.withLock {
            requests.append(request)
            return steps.isEmpty ? nil : steps.removeFirst()
        }
        guard let step else {
            fatalError("MockHTTPTransport: unexpected request to \(request.url?.absoluteString ?? "?")")
        }
        return try step.handler(request)
    }

    static func httpResponse(
        url: URL, status: Int, headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: headers)!
    }
}

/// Records sleeps instead of waiting, and lets tests advance time.
final class TestClock: RESTClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    private(set) var sleeps: [TimeInterval] = []

    init(now: Date = Date(timeIntervalSince1970: 1_000_000)) {
        self._now = now
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return _now
    }

    func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        lock.withLock {
            sleeps.append(seconds)
            _now = _now.addingTimeInterval(seconds)
        }
    }
}
