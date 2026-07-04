import Foundation

/// Result of the global `spotlight` search: users and rooms the caller can
/// reach (excludes rooms already joined).
public struct SpotlightResult: Decodable, Sendable {
    public var users: [User]
    public var rooms: [Room]

    public struct User: Decodable, Sendable, Identifiable, Equatable {
        public var id: String { _id }
        public let _id: String
        public var username: String?
        public var name: String?
        public var status: String?
        public var avatarETag: String?
    }
}

public enum DirectoryType: String, Sendable {
    case users
    case channels
    case teams
}

/// One row of the workspace directory. Field presence depends on the
/// searched `DirectoryType`.
public struct DirectoryEntry: Decodable, Sendable, Identifiable, Equatable {
    public var id: String { _id }
    public let _id: String
    // Channels/teams
    public var name: String?
    public var fname: String?
    public var t: RoomType?
    public var usersCount: Int?
    public var topic: String?
    public var ts: Date?
    // Users
    public var username: String?
    public var nickname: String?
    public var avatarETag: String?
    public var createdAt: Date?
}

struct DirectoryResponse: Decodable, Sendable {
    var result: [DirectoryEntry]
    var count: Int?
    var offset: Int?
    var total: Int?
}

struct UserInfoResponse: Decodable, Sendable {
    var user: UserProfile
}

extension API {
    enum Search {
        static func chatSearch(
            roomId: String, text: String, count: Int, offset: Int
        ) -> Endpoint<MessagesResponse> {
            .get("chat.search", query: [
                URLQueryItem(name: "roomId", value: roomId),
                URLQueryItem(name: "searchText", value: text),
                URLQueryItem(name: "count", value: String(count)),
                URLQueryItem(name: "offset", value: String(offset)),
            ])
        }

        static func spotlight(query: String) -> Endpoint<SpotlightResult> {
            .get("spotlight", query: [URLQueryItem(name: "query", value: query)])
        }

        static func directory(
            text: String, type: DirectoryType, count: Int, offset: Int
        ) -> Endpoint<DirectoryResponse> {
            .get("directory", query: [
                URLQueryItem(name: "text", value: text),
                URLQueryItem(name: "type", value: type.rawValue),
                URLQueryItem(name: "count", value: String(count)),
                URLQueryItem(name: "offset", value: String(offset)),
            ])
        }
    }

    enum Users {
        static func info(username: String) -> Endpoint<UserInfoResponse> {
            .get("users.info", query: [URLQueryItem(name: "username", value: username)])
        }

        static func info(userId: String) -> Endpoint<UserInfoResponse> {
            .get("users.info", query: [URLQueryItem(name: "userId", value: userId)])
        }
    }
}
