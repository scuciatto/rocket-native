import Testing
import Foundation
@testable import RocketChatSDK

private let serverURL = URL(string: "https://chat.example.com")!

@Suite struct RateLimitTests {
    @Test func retriesOnceAfter429UsingResetHeader() async throws {
        let clock = TestClock()
        let resetMillis = (clock.now.timeIntervalSince1970 + 7) * 1000
        let transport = MockHTTPTransport()
        transport.respond(
            status: 429,
            json: #"{"success": false, "error": "too many requests"}"#,
            headers: ["x-ratelimit-reset": String(resetMillis)])
        transport.respond(json: #"{"_id": "uid-9", "success": true}"#)

        let client = RocketChatClient(
            serverURL: serverURL, transport: transport, clock: clock)
        await client.adopt(credentials: AuthCredentials(authToken: "t", userId: "uid-9"))

        let me = try await client.me()
        #expect(me._id == "uid-9")
        #expect(clock.sleeps.count == 1)
        #expect(abs(clock.sleeps[0] - 7) < 0.01)
    }

    @Test func secondConsecutive429Throws() async throws {
        let clock = TestClock()
        let transport = MockHTTPTransport()
        let limited = #"{"success": false, "error": "too many requests"}"#
        transport.respond(status: 429, json: limited)
        transport.respond(status: 429, json: limited)

        let client = RocketChatClient(
            serverURL: serverURL, transport: transport, clock: clock)
        await client.adopt(credentials: AuthCredentials(authToken: "t", userId: "uid-9"))

        do {
            _ = try await client.me()
            Issue.record("Expected rateLimited to be thrown")
        } catch RocketChatError.rateLimited {
            // expected
        }
    }

    @Test func exhaustedBudgetDelaysNextCallToSamePath() async throws {
        let clock = TestClock()
        let resetMillis = (clock.now.timeIntervalSince1970 + 12) * 1000
        let transport = MockHTTPTransport()
        transport.respond(
            json: #"{"_id": "uid-9", "success": true}"#,
            headers: [
                "x-ratelimit-remaining": "0",
                "x-ratelimit-reset": String(resetMillis),
            ])
        transport.respond(json: #"{"_id": "uid-9", "success": true}"#)

        let client = RocketChatClient(
            serverURL: serverURL, transport: transport, clock: clock)
        await client.adopt(credentials: AuthCredentials(authToken: "t", userId: "uid-9"))

        _ = try await client.me()
        _ = try await client.me()
        #expect(clock.sleeps.count == 1)
        #expect(abs(clock.sleeps[0] - 12) < 0.01)
    }
}
