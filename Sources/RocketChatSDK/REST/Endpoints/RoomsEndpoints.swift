import Foundation

/// `{update, remove}` envelope shared by `rooms.get` and `subscriptions.get`.
struct DeltaResponse<Record: Decodable & Sendable>: Decodable, Sendable {
    var update: [Record]
    var remove: [Record]?
}

extension API {
    enum Rooms {
        static func get(updatedSince: Date? = nil) -> Endpoint<DeltaResponse<Room>> {
            var query: [URLQueryItem] = []
            if let updatedSince {
                query.append(URLQueryItem(
                    name: "updatedSince", value: RCJSON.syncTimestamp(updatedSince)))
            }
            return .get("rooms.get", query: query)
        }
    }

    enum Subscriptions {
        static func get(updatedSince: Date? = nil) -> Endpoint<DeltaResponse<Subscription>> {
            var query: [URLQueryItem] = []
            if let updatedSince {
                query.append(URLQueryItem(
                    name: "updatedSince", value: RCJSON.syncTimestamp(updatedSince)))
            }
            return .get("subscriptions.get", query: query)
        }

        static func read(roomId: String) -> Endpoint<SuccessResponse> {
            struct Body: Encodable {
                var rid: String
            }
            return .post("subscriptions.read", body: Body(rid: roomId))
        }

        static func unread(roomId: String) -> Endpoint<SuccessResponse> {
            struct Body: Encodable {
                var roomId: String
            }
            return .post("subscriptions.unread", body: Body(roomId: roomId))
        }
    }
}
