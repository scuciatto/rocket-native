import Foundation

public enum ThreadFilter: String, Sendable {
    case all
    case following
    case unread
}

struct ThreadsListResponse: Decodable, Sendable {
    var threads: [Message]
    var total: Int?
    var count: Int?
    var offset: Int?
}

/// `chat.syncThreadMessages` wraps the delta in a `messages` key; be lenient
/// about it also being a flat array (shape has drifted across versions).
struct SyncThreadMessagesResponse: Decodable, Sendable {
    var update: [Message]
    var remove: [Message]

    private enum CodingKeys: String, CodingKey {
        case messages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try? container.decode(DeltaResponse<Message>.self, forKey: .messages) {
            update = nested.update
            remove = nested.remove ?? []
        } else if let flat = try? container.decode([Message].self, forKey: .messages) {
            update = flat
            remove = []
        } else {
            update = []
            remove = []
        }
    }
}

extension API.Chat {
    static func getThreadsList(
        roomId: String, filter: ThreadFilter, text: String?, count: Int, offset: Int
    ) -> Endpoint<ThreadsListResponse> {
        var query = [
            URLQueryItem(name: "rid", value: roomId),
            URLQueryItem(name: "type", value: filter.rawValue),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let text, !text.isEmpty {
            query.append(URLQueryItem(name: "text", value: text))
        }
        return .get("chat.getThreadsList", query: query)
    }

    static func getThreadMessages(
        threadId: String, count: Int, offset: Int
    ) -> Endpoint<MessagesResponse> {
        .get("chat.getThreadMessages", query: [
            URLQueryItem(name: "tmid", value: threadId),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "sort", value: #"{"ts":-1}"#),
        ])
    }

    static func syncThreadMessages(
        threadId: String, updatedSince: Date
    ) -> Endpoint<SyncThreadMessagesResponse> {
        .get("chat.syncThreadMessages", query: [
            URLQueryItem(name: "tmid", value: threadId),
            URLQueryItem(name: "updatedSince", value: RCJSON.syncTimestamp(updatedSince)),
        ])
    }

    static func followMessage(messageId: String) -> Endpoint<SuccessResponse> {
        struct Body: Encodable {
            var mid: String
        }
        return .post("chat.followMessage", body: Body(mid: messageId))
    }

    static func unfollowMessage(messageId: String) -> Endpoint<SuccessResponse> {
        struct Body: Encodable {
            var mid: String
        }
        return .post("chat.unfollowMessage", body: Body(mid: messageId))
    }
}
