import Foundation

public struct UserProfile: Codable, Sendable, Identifiable, Equatable {
    public var id: String { _id }
    public let _id: String
    public var username: String?
    public var name: String?
    public var emails: [Email]?
    public var status: String?
    public var roles: [String]?
    public var active: Bool?
    public var avatarETag: String?

    public struct Email: Codable, Sendable, Equatable {
        public var address: String
        public var verified: Bool?
    }

    public init(
        _id: String, username: String? = nil, name: String? = nil,
        emails: [Email]? = nil, status: String? = nil, roles: [String]? = nil,
        active: Bool? = nil, avatarETag: String? = nil
    ) {
        self._id = _id
        self.username = username
        self.name = name
        self.emails = emails
        self.status = status
        self.roles = roles
        self.active = active
        self.avatarETag = avatarETag
    }
}

public struct MiniUser: Codable, Sendable, Equatable {
    public let _id: String
    public var username: String?
    public var name: String?
}

/// A user's online status, from REST `users.presence` or the presence stream.
public enum PresenceStatus: String, Codable, Sendable {
    case online, away, busy, offline
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PresenceStatus(rawValue: raw) ?? .unknown
    }

    /// Stream status codes (`PresenceStatusCode`): 0 offline, 1 online,
    /// 2 away, 3 busy. Disabled users arrive as offline.
    init(code: Int) {
        switch code {
        case 0: self = .offline
        case 1: self = .online
        case 2: self = .away
        case 3: self = .busy
        default: self = .unknown
        }
    }
}

public struct UserPresence: Codable, Sendable, Equatable {
    public let userId: String
    public var username: String?
    public var status: PresenceStatus
    public var statusText: String?

    public init(
        userId: String, username: String? = nil,
        status: PresenceStatus, statusText: String? = nil
    ) {
        self.userId = userId
        self.username = username
        self.status = status
        self.statusText = statusText
    }
}
