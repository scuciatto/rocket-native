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
