import Foundation

struct ChannelResponse: Decodable, Sendable {
    var channel: Room
}

struct IMCreateResponse: Decodable, Sendable {
    var room: Room
}

extension API {
    enum RoomActions {
        static func joinChannel(roomId: String) -> Endpoint<ChannelResponse> {
            struct Body: Encodable {
                var roomId: String
            }
            return .post("channels.join", body: Body(roomId: roomId))
        }

        static func createDM(username: String) -> Endpoint<IMCreateResponse> {
            struct Body: Encodable {
                var username: String
            }
            return .post("im.create", body: Body(username: username))
        }
    }
}
