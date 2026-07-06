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

private let roomsGetJSON = """
{
  "update": [
    {
      "_id": "general-id", "t": "c", "name": "general", "fname": "general",
      "topic": "Company chat", "msgs": 100, "usersCount": 12,
      "ts": "2023-01-01T00:00:00.000Z", "lm": "2024-01-02T10:00:00.000Z",
      "_updatedAt": "2024-01-02T10:00:00.000Z",
      "lastMessage": {
        "_id": "m-last", "rid": "general-id", "msg": "see you there",
        "ts": "2024-01-02T10:00:00.000Z",
        "u": {"_id": "uid-2", "username": "ana", "name": "Ana"}
      }
    },
    {
      "_id": "dm-id", "t": "d", "usernames": ["felipe", "ana"],
      "uids": ["uid-9", "uid-2"],
      "ts": "2023-06-01T00:00:00.000Z", "lm": "2024-01-03T08:30:00.000Z",
      "_updatedAt": "2024-01-03T08:30:00.000Z"
    }
  ],
  "remove": [],
  "success": true
}
"""

private let subscriptionsGetJSON = """
{
  "update": [
    {
      "_id": "sub-1", "rid": "general-id", "name": "general", "fname": "general",
      "t": "c", "open": true, "alert": false, "unread": 3,
      "userMentions": 1, "groupMentions": 0, "f": true,
      "ts": "2023-01-01T00:00:00.000Z", "_updatedAt": "2024-01-02T10:00:00.000Z",
      "u": {"_id": "uid-9", "username": "felipe"}
    },
    {
      "_id": "sub-2", "rid": "dm-id", "name": "ana", "fname": "Ana",
      "t": "d", "open": true, "alert": true, "unread": 5,
      "tunread": ["tm-1", "tm-2"],
      "ts": "2023-06-01T00:00:00.000Z", "_updatedAt": "2024-01-03T08:30:00.000Z",
      "u": {"_id": "uid-9", "username": "felipe"}
    }
  ],
  "remove": [],
  "success": true
}
"""

@Suite struct RoomListTests {
    @Test func roomsJoinsSubscriptionsAndSortsByActivity() async throws {
        let transport = MockHTTPTransport()
        transport.respond(path: "rooms.get", json: roomsGetJSON)
        transport.respond(path: "subscriptions.get", json: subscriptionsGetJSON)

        let client = await makeClient(transport)
        let rooms = try await client.rooms()

        #expect(rooms.count == 2)
        // DM has the most recent activity, so it sorts first.
        #expect(rooms[0].id == "dm-id")
        #expect(rooms[0].displayName == "Ana")
        #expect(rooms[0].type == .directMessage)
        #expect(rooms[0].unread == 5)
        #expect(rooms[0].alert)
        #expect(rooms[0].unreadThreads == 2)

        #expect(rooms[1].id == "general-id")
        #expect(rooms[1].displayName == "general")
        #expect(rooms[1].mentions == 1)
        #expect(rooms[1].favorite)
        #expect(rooms[1].lastMessage?.msg == "see you there")
    }
}

private let syncMessagesJSON = """
{
  "result": {
    "updated": [
      {
        "_id": "m-1", "rid": "general-id", "msg": "hello **world**",
        "ts": "2024-01-02T10:00:00.000Z",
        "u": {"_id": "uid-2", "username": "ana", "name": "Ana"},
        "_updatedAt": "2024-01-02T10:00:00.000Z",
        "md": [
          {"type": "PARAGRAPH", "value": [
            {"type": "PLAIN_TEXT", "value": "hello "},
            {"type": "BOLD", "value": [{"type": "PLAIN_TEXT", "value": "world"}]}
          ]}
        ],
        "reactions": {":thumbsup:": {"usernames": ["felipe"]}},
        "attachments": [{"title": "doc.pdf", "title_link": "/file-upload/x/doc.pdf"}]
      },
      {
        "_id": "m-2", "rid": "general-id", "msg": "reply in thread",
        "ts": "2024-01-02T10:05:00.000Z",
        "u": {"_id": "uid-9", "username": "felipe"},
        "tmid": "m-1"
      },
      {
        "_id": "m-3", "rid": "general-id", "msg": "ana joined the channel",
        "t": "uj", "ts": "2024-01-02T10:06:00.000Z",
        "u": {"_id": "uid-2", "username": "ana"}
      }
    ],
    "deleted": [
      {"_id": "m-0", "_deletedAt": "2024-01-02T09:59:00.000Z"}
    ]
  },
  "success": true
}
"""

@Suite struct MessageTests {
    @Test func syncMessagesDecodesUpdatesAndDeletes() async throws {
        let transport = MockHTTPTransport()
        transport.expect { request in
            let query = URLComponents(
                url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(query?.first { $0.name == "roomId" }?.value == "general-id")
            #expect(query?.first { $0.name == "lastUpdate" }?.value?.hasSuffix("Z") == true)
            return (Data(syncMessagesJSON.utf8),
                    MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }

        let client = await makeClient(transport)
        let delta = try await client.syncMessages(
            roomId: "general-id", since: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(delta.updated.count == 3)
        let first = delta.updated[0]
        #expect(first.msg == "hello **world**")
        #expect(first.reactions?[":thumbsup:"]?.usernames == ["felipe"])
        #expect(first.attachments?.first?.title == "doc.pdf")
        #expect(first.md?.arrayValue?.first?["type"]?.stringValue == "PARAGRAPH")
        #expect(delta.updated[1].tmid == "m-1")
        #expect(delta.updated[2].t == "uj")
        #expect(delta.deleted.map(\._id) == ["m-0"])
    }

    @Test func sendGeneratesClientMessageId() async throws {
        let transport = MockHTTPTransport()
        transport.expect { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
                as? [String: Any]
            let message = body?["message"] as? [String: Any]
            let clientId = message?["_id"] as? String
            #expect(clientId?.count == 17)
            #expect(message?["rid"] as? String == "general-id")
            #expect(message?["msg"] as? String == "hi!")
            let echoed = """
            {"message": {"_id": "\(clientId ?? "")", "rid": "general-id", "msg": "hi!",
             "ts": "2024-01-02T10:07:00.000Z",
             "u": {"_id": "uid-9", "username": "felipe"}}, "success": true}
            """
            return (Data(echoed.utf8),
                    MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }

        let client = await makeClient(transport)
        let sent = try await client.send(text: "hi!", roomId: "general-id")
        #expect(sent.rid == "general-id")
        #expect(sent._id.count == 17)
    }

    @Test func sendIntoThreadCarriesTmid() async throws {
        let transport = MockHTTPTransport()
        transport.expect { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
                as? [String: Any]
            let message = body?["message"] as? [String: Any]
            #expect(message?["tmid"] as? String == "m-1")
            return (Data("""
                {"message": {"_id": "x", "rid": "general-id", "msg": "reply",
                 "ts": "2024-01-02T10:08:00.000Z", "tmid": "m-1",
                 "u": {"_id": "uid-9", "username": "felipe"}}, "success": true}
                """.utf8),
                MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }

        let client = await makeClient(transport)
        let sent = try await client.send(text: "reply", roomId: "general-id", threadId: "m-1")
        #expect(sent.tmid == "m-1")
    }

    @Test func historyRoutesByRoomType() async throws {
        let transport = MockHTTPTransport()
        transport.respond(
            path: "groups.messages",
            json: #"{"messages": [], "count": 0, "offset": 0, "total": 0, "success": true}"#)

        let client = await makeClient(transport)
        let messages = try await client.history(roomId: "priv-1", type: .privateGroup)
        #expect(messages.isEmpty)
    }
}

@Suite struct UnreadStateTests {
    @Test func roomSummaryCarriesLastSeen() throws {
        let ls = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = RoomSummary(
            room: Room(_id: "r1", t: .channel, name: "general"),
            subscription: Subscription(
                _id: "s1", rid: "r1", t: .channel, unread: 3, ls: ls))
        #expect(summary.lastSeen == ls)
        #expect(summary.unread == 3)
    }

    @Test func markUnreadPostsThenCatchesUpSidebar() async throws {
        let transport = MockHTTPTransport()
        transport.expect(path: "subscriptions.unread") { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!)
                as? [String: Any]
            #expect(body?["roomId"] as? String == "r1")
            return (Data(#"{"success": true}"#.utf8),
                    MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }
        transport.respond(path: "rooms.get", json: #"{"update": [], "remove": [], "success": true}"#)
        transport.respond(path: "subscriptions.get", json: #"{"update": [], "remove": [], "success": true}"#)

        let client = await makeClient(transport)
        try await client.markUnread(roomId: "r1")

        let paths = transport.requests.compactMap { $0.url?.path() }
        #expect(paths.contains { $0.hasSuffix("subscriptions.unread") })
        #expect(paths.contains { $0.hasSuffix("rooms.get") })
    }
}
