import Testing
import Foundation
@testable import RocketChatSDK

private let serverURL = URL(string: "https://chat.example.com")!

private func makeEngine(
    _ transport: MockHTTPTransport, clock: TestClock = TestClock()
) async -> SyncEngine {
    let auth = AuthSession()
    await auth.set(AuthCredentials(authToken: "tok", userId: "uid-9"))
    await auth.setProfile(UserProfile(_id: "uid-9", username: "felipe"))
    let rest = RESTClient(
        serverURL: serverURL, transport: transport, auth: auth, clock: clock)
    return SyncEngine(rest: rest, auth: auth, clock: clock)
}

private func queryValue(_ request: URLRequest, _ name: String) -> String? {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == name }?.value
}

private let emptyDeltaJSON = #"{"update": [], "remove": [], "success": true}"#

@Suite struct SyncEngineSidebarTests {
    @Test func sidebarTicksAdvanceUpdatedSince() async throws {
        let transport = MockHTTPTransport()
        // First tick: full fetch, no updatedSince.
        transport.respond(path: "rooms.get", json: """
            {"update": [{"_id": "r1", "t": "c", "name": "general",
              "_updatedAt": "2024-01-02T10:00:00.000Z"}], "remove": [], "success": true}
            """)
        transport.respond(path: "subscriptions.get", json: """
            {"update": [{"_id": "s1", "rid": "r1", "name": "general", "t": "c",
              "unread": 1, "_updatedAt": "2024-01-02T10:00:05.000Z"}],
             "remove": [], "success": true}
            """)
        // Second tick: empty deltas.
        transport.respond(path: "rooms.get", json: emptyDeltaJSON)
        transport.respond(path: "subscriptions.get", json: emptyDeltaJSON)

        let engine = await makeEngine(transport)
        await engine.tickSidebar()

        let list = await engine.roomStore.snapshot()
        #expect(list.count == 1)
        #expect(list[0].unread == 1)

        await engine.tickSidebar()
        let secondTickRequests = transport.requests.suffix(2)
        let roomsRequest = secondTickRequests.first {
            $0.url!.path().hasSuffix("rooms.get")
        }
        let subsRequest = secondTickRequests.first {
            $0.url!.path().hasSuffix("subscriptions.get")
        }
        #expect(queryValue(try #require(roomsRequest), "updatedSince")
            == "2024-01-02T10:00:00.000Z")
        #expect(queryValue(try #require(subsRequest), "updatedSince")
            == "2024-01-02T10:00:05.000Z")
    }
}

@Suite struct SyncEngineRoomTests {
    @Test func openRoomLoadsPageThenTicksWithHighWater() async throws {
        let transport = MockHTTPTransport()
        transport.respond(path: "channels.messages", json: """
            {"messages": [
              {"_id": "m2", "rid": "r1", "msg": "newest",
               "ts": "2024-01-02T10:05:00.000Z", "_updatedAt": "2024-01-02T10:05:00.000Z",
               "u": {"_id": "u2", "username": "ana"}},
              {"_id": "m1", "rid": "r1", "msg": "older",
               "ts": "2024-01-02T10:00:00.000Z", "_updatedAt": "2024-01-02T10:00:00.000Z",
               "u": {"_id": "u2", "username": "ana"}}
            ], "count": 2, "offset": 0, "total": 2, "success": true}
            """)
        transport.respond(path: "chat.syncMessages", json: """
            {"result": {"updated": [
              {"_id": "m3", "rid": "r1", "msg": "brand new",
               "ts": "2024-01-02T10:06:00.000Z", "_updatedAt": "2024-01-02T10:06:00.000Z",
               "u": {"_id": "u2", "username": "ana"}}
            ], "deleted": [{"_id": "m1", "_deletedAt": "2024-01-02T10:06:30.000Z"}]},
             "success": true}
            """)

        let engine = await makeEngine(transport)
        try await engine.openRoom("r1", startPolling: false)

        var snapshot = await engine.messageStore.snapshot("r1")
        #expect(snapshot.entries.map(\.id) == ["m1", "m2"])

        await engine.tickRoom("r1")
        snapshot = await engine.messageStore.snapshot("r1")
        #expect(snapshot.entries.map(\.id) == ["m2", "m3"])

        // The sync request must carry the initial page's high-water mark.
        let syncRequest = transport.requests.first {
            $0.url!.path().hasSuffix("chat.syncMessages")
        }
        #expect(queryValue(try #require(syncRequest), "lastUpdate")
            == "2024-01-02T10:05:00.000Z")
    }

    @Test func sendInsertsPendingThenConfirms() async throws {
        let transport = MockHTTPTransport()
        transport.respond(path: "channels.messages", json:
            #"{"messages": [], "count": 0, "offset": 0, "total": 0, "success": true}"#)
        transport.expect(path: "chat.sendMessage") { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!)
                as? [String: Any]
            let message = body?["message"] as? [String: Any]
            let id = message?["_id"] as? String ?? "?"
            return (Data("""
                {"message": {"_id": "\(id)", "rid": "r1", "msg": "hello",
                 "ts": "2024-01-02T11:00:00.000Z", "_updatedAt": "2024-01-02T11:00:00.000Z",
                 "u": {"_id": "uid-9", "username": "felipe"}}, "success": true}
                """.utf8),
                MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }
        // Post-send catch-up tick.
        transport.respond(path: "chat.syncMessages", json:
            #"{"result": {"updated": [], "deleted": []}, "success": true}"#)

        let engine = await makeEngine(transport)
        try await engine.openRoom("r1", startPolling: false)
        try await engine.send(text: "hello", roomId: "r1")

        let snapshot = await engine.messageStore.snapshot("r1")
        #expect(snapshot.entries.count == 1)
        #expect(snapshot.entries[0].delivery == .sent)
        #expect(snapshot.entries[0].message.msg == "hello")
    }

    @Test func failedSendIsMarkedFailed() async throws {
        let transport = MockHTTPTransport()
        transport.respond(path: "channels.messages", json:
            #"{"messages": [], "count": 0, "offset": 0, "total": 0, "success": true}"#)
        transport.respond(path: "chat.sendMessage", status: 500, json:
            #"{"success": false, "error": "internal"}"#)

        let engine = await makeEngine(transport)
        try await engine.openRoom("r1", startPolling: false)
        await #expect(throws: RocketChatError.self) {
            try await engine.send(text: "hello", roomId: "r1")
        }

        let snapshot = await engine.messageStore.snapshot("r1")
        #expect(snapshot.entries.count == 1)
        #expect(snapshot.entries[0].delivery == .failed)
    }

    @Test func loadOlderPagesByCurrentCount() async throws {
        let transport = MockHTTPTransport()
        transport.respond(path: "channels.messages", json: """
            {"messages": [
              {"_id": "m2", "rid": "r1", "msg": "b", "ts": "2024-01-02T10:01:00.000Z",
               "u": {"_id": "u2", "username": "ana"}},
              {"_id": "m1", "rid": "r1", "msg": "a", "ts": "2024-01-02T10:00:00.000Z",
               "u": {"_id": "u2", "username": "ana"}}
            ], "count": 2, "offset": 0, "total": 3, "success": true}
            """)
        transport.expect(path: "channels.messages") { request in
            #expect(queryValue(request, "offset") == "2")
            return (Data("""
                {"messages": [
                  {"_id": "m0", "rid": "r1", "msg": "oldest",
                   "ts": "2024-01-02T09:00:00.000Z",
                   "u": {"_id": "u2", "username": "ana"}}
                ], "count": 1, "offset": 2, "total": 3, "success": true}
                """.utf8),
                MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }

        let engine = await makeEngine(transport)
        try await engine.openRoom("r1", startPolling: false)
        try await engine.loadOlder("r1")

        let snapshot = await engine.messageStore.snapshot("r1")
        #expect(snapshot.entries.map(\.id) == ["m0", "m1", "m2"])
    }
}
