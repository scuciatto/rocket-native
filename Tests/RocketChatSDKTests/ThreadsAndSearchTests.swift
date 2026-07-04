import Testing
import Foundation
@testable import RocketChatSDK

private let serverURL = URL(string: "https://chat.example.com")!

private func makeClient(_ transport: MockHTTPTransport) async -> RocketChatClient {
    let client = RocketChatClient(
        serverURL: serverURL, transport: transport, clock: TestClock())
    await client.adopt(credentials: AuthCredentials(authToken: "tok", userId: "uid-9"))
    return client
}

@Suite struct ThreadsTests {
    @Test func threadsListDecodesParents() async throws {
        let transport = MockHTTPTransport()
        transport.expect { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems
            #expect(query?.first { $0.name == "rid" }?.value == "r1")
            #expect(query?.first { $0.name == "type" }?.value == "unread")
            return (Data("""
                {"threads": [
                  {"_id": "t1", "rid": "r1", "msg": "topic?", "tcount": 4,
                   "tlm": "2024-01-02T12:00:00.000Z", "ts": "2024-01-02T10:00:00.000Z",
                   "replies": ["uid-9"], "u": {"_id": "u2", "username": "ana"}}
                ], "total": 1, "count": 1, "offset": 0, "success": true}
                """.utf8),
                MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }

        let client = await makeClient(transport)
        let threads = try await client.threads(in: "r1", filter: .unread)
        #expect(threads.count == 1)
        #expect(threads[0].tcount == 4)
    }

    @Test func openThreadLoadsRepliesAndSyncsSeparatelyFromRoom() async throws {
        let transport = MockHTTPTransport()
        transport.respond(path: "chat.getThreadMessages", json: """
            {"messages": [
              {"_id": "reply-1", "rid": "r1", "msg": "first reply", "tmid": "t1",
               "ts": "2024-01-02T10:01:00.000Z", "_updatedAt": "2024-01-02T10:01:00.000Z",
               "u": {"_id": "u2", "username": "ana"}}
            ], "count": 1, "offset": 0, "total": 1, "success": true}
            """)
        transport.expect(path: "chat.syncThreadMessages") { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems
            #expect(query?.first { $0.name == "tmid" }?.value == "t1")
            #expect(query?.first { $0.name == "updatedSince" }?.value
                == "2024-01-02T10:01:00.000Z")
            return (Data("""
                {"messages": {"update": [
                  {"_id": "reply-2", "rid": "r1", "msg": "second", "tmid": "t1",
                   "ts": "2024-01-02T10:02:00.000Z", "_updatedAt": "2024-01-02T10:02:00.000Z",
                   "u": {"_id": "uid-9", "username": "felipe"}}
                ], "remove": []}, "success": true}
                """.utf8),
                MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }

        let client = await makeClient(transport)
        try await client.engine.openThread("t1", startPolling: false)
        await client.engine.tickThread("t1")

        let handle = ThreadHandle(threadId: "t1", roomId: "r1", engine: client.engine)
        let snapshot = await handle.timeline()
        #expect(snapshot.entries.map(\.id) == ["reply-1", "reply-2"])

        // The room window is untouched by thread syncs.
        let roomSnapshot = await client.engine.messageStore.snapshot("r1")
        #expect(roomSnapshot.entries.isEmpty)
    }
}

@Suite struct SearchAndDirectoryTests {
    @Test func searchMessagesHitsChatSearch() async throws {
        let transport = MockHTTPTransport()
        transport.expect { request in
            #expect(request.url?.path().hasSuffix("chat.search") == true)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems
            #expect(query?.first { $0.name == "searchText" }?.value == "deploy plan")
            return (Data("""
                {"messages": [
                  {"_id": "m9", "rid": "r1", "msg": "the deploy plan is ready",
                   "ts": "2024-01-02T09:00:00.000Z", "u": {"_id": "u2", "username": "ana"}}
                ], "success": true}
                """.utf8),
                MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }

        let client = await makeClient(transport)
        let hits = try await client.searchMessages(in: "r1", text: "deploy plan")
        #expect(hits.count == 1)
    }

    @Test func spotlightDecodesUsersAndRooms() async throws {
        let transport = MockHTTPTransport()
        transport.respond(json: """
            {"users": [{"_id": "u5", "username": "carlos", "name": "Carlos",
                        "status": "online", "avatarETag": "abc"}],
             "rooms": [{"_id": "r7", "t": "c", "name": "random"}],
             "success": true}
            """)

        let client = await makeClient(transport)
        let result = try await client.spotlight("car")
        #expect(result.users.first?.username == "carlos")
        #expect(result.rooms.first?.name == "random")
    }

    @Test func directoryPaginates() async throws {
        let transport = MockHTTPTransport()
        transport.expect { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems
            #expect(query?.first { $0.name == "type" }?.value == "users")
            #expect(query?.contains { $0.name == "query" } == false)
            return (Data("""
                {"result": [{"_id": "u5", "username": "carlos", "createdAt":
                  "2023-05-01T00:00:00.000Z", "avatarETag": "abc"}],
                 "count": 1, "offset": 0, "total": 42, "success": true}
                """.utf8),
                MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }

        let client = await makeClient(transport)
        let page = try await client.directory(text: "car", type: .users)
        #expect(page.items.first?.username == "carlos")
        #expect(page.total == 42)
    }

    @Test func avatarURLIncludesFormatSizeAndEtag() async {
        let client = await makeClient(MockHTTPTransport())
        let url = client.avatarURL(username: "felipe", size: 64, etag: "xyz")
        #expect(url.absoluteString
            == "https://chat.example.com/avatar/felipe?format=png&size=64&etag=xyz")
    }
}
