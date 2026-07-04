import Foundation

public enum RoomType: String, Codable, Sendable {
    case channel = "c"
    case privateGroup = "p"
    case directMessage = "d"
    case livechat = "l"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RoomType(rawValue: raw) ?? .unknown
    }
}

/// A room record from `rooms.get`. Everything but `_id` is optional because
/// delta responses (and `remove` entries) carry partial records.
public struct Room: Codable, Sendable, Identifiable, Equatable {
    public var id: String { _id }
    public let _id: String
    public var t: RoomType?
    public var name: String?
    /// Display name (may differ from `name` when "allow special chars" is on).
    public var fname: String?
    public var topic: String?
    public var description: String?
    /// Owner/creator.
    public var u: MiniUser?
    /// Read-only room.
    public var ro: Bool?
    /// Message count.
    public var msgs: Int?
    public var usersCount: Int?
    /// For DMs: the participant usernames.
    public var usernames: [String]?
    /// Direct-message participant ids.
    public var uids: [String]?
    public var ts: Date?
    /// Timestamp of the last message.
    public var lm: Date?
    public var lastMessage: Message?
    public var _updatedAt: Date?
    /// Parent room id when this is a discussion.
    public var prid: String?
    public var teamId: String?
    public var archived: Bool?
    public var encrypted: Bool?
    public var broadcast: Bool?
}

/// The user's per-room state from `subscriptions.get`: unread counts, alert
/// flags, mention counts, open/favorite state.
public struct Subscription: Codable, Sendable, Identifiable, Equatable {
    public var id: String { _id }
    public let _id: String
    /// Room id this subscription belongs to — the join key against `Room`.
    public var rid: String
    public var name: String?
    public var fname: String?
    public var t: RoomType?
    public var u: MiniUser?
    public var open: Bool?
    public var alert: Bool?
    public var unread: Int?
    public var userMentions: Int?
    public var groupMentions: Int?
    /// Thread message ids with unread replies.
    public var tunread: [String]?
    /// Last seen.
    public var ls: Date?
    /// Last read.
    public var lr: Date?
    /// Favorite.
    public var f: Bool?
    public var ts: Date?
    public var _updatedAt: Date?
    public var roles: [String]?
}

/// Client-side join of `Room` + `Subscription` by room id — what a sidebar renders.
public struct RoomSummary: Sendable, Identifiable, Equatable {
    public let id: String
    public var type: RoomType
    public var displayName: String
    public var topic: String?
    public var unread: Int
    public var alert: Bool
    public var mentions: Int
    public var unreadThreads: Int
    public var favorite: Bool
    public var open: Bool
    public var readOnly: Bool
    public var lastMessage: Message?
    public var lastActivity: Date?

    public init(room: Room?, subscription: Subscription) {
        self.id = subscription.rid
        self.type = subscription.t ?? room?.t ?? .unknown
        self.displayName = subscription.fname ?? subscription.name
            ?? room?.fname ?? room?.name ?? subscription.rid
        self.topic = room?.topic
        self.unread = subscription.unread ?? 0
        self.alert = subscription.alert ?? false
        self.mentions = subscription.userMentions ?? 0
        self.unreadThreads = subscription.tunread?.count ?? 0
        self.favorite = subscription.f ?? false
        self.open = subscription.open ?? true
        self.readOnly = room?.ro ?? false
        self.lastMessage = room?.lastMessage
        self.lastActivity = room?.lm ?? room?.lastMessage?.ts ?? room?._updatedAt
    }
}
