import Testing
import Foundation
@testable import RocketChatSDK

private let serverURL = URL(string: "https://chat.example.com")!
private let emptyPage = #"{"messages": [], "count": 0, "offset": 0, "total": 0, "success": true}"#
private let emptySync = #"{"result": {"updated": [], "deleted": []}, "success": true}"#

private func makeClient(_ transport: MockHTTPTransport) async -> RocketChatClient {
    let client = RocketChatClient(
        serverURL: serverURL, transport: transport, clock: TestClock())
    await client.adopt(credentials: AuthCredentials(authToken: "tok", userId: "uid-9"))
    return client
}

@Suite struct RoomHandleActionTests {
    @Test func reactSendsThenCatchesUp() async throws {
        let transport = MockHTTPTransport()
        transport.respond(path: "channels.messages", json: emptyPage)
        transport.expect(path: "chat.react") { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!)
                as? [String: Any]
            #expect(body?["messageId"] as? String == "m1")
            #expect(body?["emoji"] as? String == ":tada:")
            return (Data(#"{"success": true}"#.utf8),
                    MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }
        transport.respond(path: "chat.syncMessages", json: emptySync)

        let client = await makeClient(transport)
        try await client.engine.openRoom("r1", startPolling: false)
        let handle = RoomHandle(roomId: "r1", engine: client.engine, client: client)
        try await handle.react(messageId: "m1", emoji: ":tada:")

        // The catch-up tick must have fired after the action.
        #expect(transport.requests.last?.url?.path().hasSuffix("chat.syncMessages") == true)
    }

    @Test func editSendsThenCatchesUp() async throws {
        let transport = MockHTTPTransport()
        transport.respond(path: "channels.messages", json: emptyPage)
        transport.expect(path: "chat.update") { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!)
                as? [String: Any]
            #expect(body?["msgId"] as? String == "m1")
            #expect(body?["roomId"] as? String == "r1")
            #expect(body?["text"] as? String == "fixed")
            return (Data("""
                {"message": {"_id": "m1", "rid": "r1", "msg": "fixed",
                 "ts": "2024-01-02T10:00:00.000Z",
                 "u": {"_id": "uid-9", "username": "felipe"}}, "success": true}
                """.utf8),
                MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }
        transport.respond(path: "chat.syncMessages", json: emptySync)

        let client = await makeClient(transport)
        try await client.engine.openRoom("r1", startPolling: false)
        let handle = RoomHandle(roomId: "r1", engine: client.engine, client: client)
        try await handle.edit(messageId: "m1", text: "fixed")

        #expect(transport.requests.last?.url?.path().hasSuffix("chat.syncMessages") == true)
    }

    @Test func deleteSendsThenCatchesUp() async throws {
        let transport = MockHTTPTransport()
        transport.respond(path: "channels.messages", json: emptyPage)
        transport.expect(path: "chat.delete") { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!)
                as? [String: Any]
            #expect(body?["msgId"] as? String == "m1")
            return (Data(#"{"success": true}"#.utf8),
                    MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }
        transport.respond(path: "chat.syncMessages", json: emptySync)

        let client = await makeClient(transport)
        try await client.engine.openRoom("r1", startPolling: false)
        let handle = RoomHandle(roomId: "r1", engine: client.engine, client: client)
        try await handle.delete(messageId: "m1")

        #expect(transport.requests.last?.url?.path().hasSuffix("chat.syncMessages") == true)
    }
}

@Suite struct ThreadHandleActionTests {
    @Test func threadReactCatchesUpTheThreadNotTheRoom() async throws {
        let transport = MockHTTPTransport()
        transport.respond(path: "chat.getThreadMessages", json: emptyPage)
        transport.respond(path: "chat.react", json: #"{"success": true}"#)
        transport.respond(path: "chat.syncThreadMessages", json:
            #"{"messages": {"update": [], "remove": []}, "success": true}"#)

        let client = await makeClient(transport)
        try await client.engine.openThread("t1", startPolling: false)
        let handle = ThreadHandle(
            threadId: "t1", roomId: "r1", engine: client.engine, client: client)
        try await handle.react(messageId: "reply-1", emoji: ":eyes:")

        #expect(transport.requests.last?.url?.path()
            .hasSuffix("chat.syncThreadMessages") == true)
    }
}
