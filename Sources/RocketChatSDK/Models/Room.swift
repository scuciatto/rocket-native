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
    public var t: RoomType? = nil
    public var name: String? = nil
    /// Display name (may differ from `name` when "allow special chars" is on).
    public var fname: String? = nil
    public var topic: String? = nil
    public var description: String? = nil
    /// Owner/creator.
    public var u: MiniUser? = nil
    /// Read-only room.
    public var ro: Bool? = nil
    /// Message count.
    public var msgs: Int? = nil
    public var usersCount: Int? = nil
    /// For DMs: the participant usernames.
    public var usernames: [String]? = nil
    /// Direct-message participant ids.
    public var uids: [String]? = nil
    public var ts: Date? = nil
    /// Timestamp of the last message.
    public var lm: Date? = nil
    public var lastMessage: Message? = nil
    public var _updatedAt: Date? = nil
    /// Parent room id when this is a discussion.
    public var prid: String? = nil
    public var teamId: String? = nil
    public var archived: Bool? = nil
    public var encrypted: Bool? = nil
    public var broadcast: Bool? = nil
}

/// The user's per-room state from `subscriptions.get`: unread counts, alert
/// flags, mention counts, open/favorite state.
public struct Subscription: Codable, Sendable, Identifiable, Equatable {
    public var id: String { _id }
    public let _id: String
    /// Room id this subscription belongs to — the join key against `Room`.
    public var rid: String
    public var name: String? = nil
    public var fname: String? = nil
    public var t: RoomType? = nil
    public var u: MiniUser? = nil
    public var open: Bool? = nil
    public var alert: Bool? = nil
    public var unread: Int? = nil
    public var userMentions: Int? = nil
    public var groupMentions: Int? = nil
    /// Thread message ids with unread replies.
    public var tunread: [String]? = nil
    /// Last seen.
    public var ls: Date? = nil
    /// Last read.
    public var lr: Date? = nil
    /// Favorite.
    public var f: Bool? = nil
    public var ts: Date? = nil
    public var _updatedAt: Date? = nil
    public var roles: [String]? = nil
}

/// Client-side join of `Room` + `Subscription` by room id — what a sidebar renders.
public struct RoomSummary: Sendable, Identifiable, Equatable {
    public let id: String
    public var type: RoomType
    public var displayName: String
    public var topic: String? = nil
    public var unread: Int
    public var alert: Bool
    public var mentions: Int
    public var unreadThreads: Int
    public var favorite: Bool
    public var open: Bool
    public var readOnly: Bool
    public var lastMessage: Message? = nil
    public var lastActivity: Date? = nil

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
