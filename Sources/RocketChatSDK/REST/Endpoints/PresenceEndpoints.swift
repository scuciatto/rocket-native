import Foundation

struct UsersPresenceResponse: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        var _id: String
        var username: String?
        var status: PresenceStatus?
        var statusText: String?
    }

    /// Empty when the server has `Presence_broadcast_disabled` on.
    var users: [Entry]
}

struct PublicSettingsResponse: Decodable, Sendable {
    struct Setting: Decodable, Sendable {
        var _id: String
        var value: JSONValue?
    }

    var settings: [Setting]
}

extension API.Users {
    /// Current status for specific users (seeds the presence stream).
    static func presence(ids: [String]) -> Endpoint<UsersPresenceResponse> {
        .get("users.presence", query: [
            URLQueryItem(name: "ids", value: ids.joined(separator: ",")),
        ])
    }
}

extension API {
    enum Settings {
        /// Selected public settings by id (comma-separated `_id`, not the
        /// disabled generic `query` param).
        static func publicValues(ids: [String]) -> Endpoint<PublicSettingsResponse> {
            .get("settings.public", query: [
                URLQueryItem(name: "_id", value: ids.joined(separator: ",")),
            ])
        }
    }
}
