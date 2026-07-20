import Foundation

struct SyncMessagesResponse: Decodable, Sendable {
    var result: Result

    struct Result: Decodable, Sendable {
        var updated: [Message]
        var deleted: [DeletedMessage]?
    }
}

struct MessagesResponse: Decodable, Sendable {
    var messages: [Message]
    var count: Int?
    var offset: Int?
    var total: Int?
}

struct SingleMessageResponse: Decodable, Sendable {
    var message: Message
}

extension API {
    enum Chat {
        /// Delta of one room's messages since `lastUpdate`: inserts, edits,
        /// and deletions in one call. This is the live-update workhorse.
        static func syncMessages(
            roomId: String, lastUpdate: Date
        ) -> Endpoint<SyncMessagesResponse> {
            .get("chat.syncMessages", query: [
                URLQueryItem(name: "roomId", value: roomId),
                URLQueryItem(name: "lastUpdate", value: RCJSON.syncTimestamp(lastUpdate)),
            ])
        }

        /// One message by id — e.g. resolving a search result's thread parent.
        static func getMessage(messageId: String) -> Endpoint<SingleMessageResponse> {
            .get("chat.getMessage", query: [
                URLQueryItem(name: "msgId", value: messageId),
            ])
        }

        static func sendMessage(
            roomId: String, text: String, messageId: String, threadId: String? = nil
        ) -> Endpoint<SingleMessageResponse> {
            struct Outgoing: Encodable {
                var _id: String
                var rid: String
                var msg: String
                var tmid: String?
            }
            struct Body: Encodable {
                var message: Outgoing
            }
            return .post("chat.sendMessage", body: Body(message: Outgoing(
                _id: messageId, rid: roomId, msg: text, tmid: threadId)))
        }

        static func update(
            roomId: String, messageId: String, text: String
        ) -> Endpoint<SingleMessageResponse> {
            struct Body: Encodable {
                var roomId: String
                var msgId: String
                var text: String
            }
            return .post("chat.update", body: Body(
                roomId: roomId, msgId: messageId, text: text))
        }

        static func delete(roomId: String, messageId: String) -> Endpoint<SuccessResponse> {
            struct Body: Encodable {
                var roomId: String
                var msgId: String
            }
            return .post("chat.delete", body: Body(roomId: roomId, msgId: messageId))
        }

        static func react(
            messageId: String, emoji: String, shouldReact: Bool? = nil
        ) -> Endpoint<SuccessResponse> {
            struct Body: Encodable {
                var messageId: String
                var emoji: String
                var shouldReact: Bool?
            }
            return .post("chat.react", body: Body(
                messageId: messageId, emoji: emoji, shouldReact: shouldReact))
        }
    }

    /// History listing is type-routed (`channels.messages` / `groups.messages`
    /// / `im.messages`); callers pass the room type from its summary.
    static func roomMessages(
        roomId: String, type: RoomType, count: Int, offset: Int
    ) -> Endpoint<MessagesResponse> {
        let path: String
        switch type {
        case .channel: path = "channels.messages"
        case .privateGroup: path = "groups.messages"
        case .directMessage, .livechat, .unknown: path = "im.messages"
        }
        return .get(path, query: [
            URLQueryItem(name: "roomId", value: roomId),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "sort", value: #"{"ts":-1}"#),
        ])
    }
}
