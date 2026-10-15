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

extension Room {
    /// Custom only so a malformed field (seen in the wild: a `lastMessage`
    /// without `_id`, an owner with `_id: null`) decodes as nil instead of
    /// failing the whole `rooms.get` page. Only `_id` is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _id = try c.decode(String.self, forKey: ._id)
        t = try? c.decodeIfPresent(RoomType.self, forKey: .t)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        fname = try? c.decodeIfPresent(String.self, forKey: .fname)
        topic = try? c.decodeIfPresent(String.self, forKey: .topic)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        u = try? c.decodeIfPresent(MiniUser.self, forKey: .u)
        ro = try? c.decodeIfPresent(Bool.self, forKey: .ro)
        msgs = try? c.decodeIfPresent(Int.self, forKey: .msgs)
        usersCount = try? c.decodeIfPresent(Int.self, forKey: .usersCount)
        usernames = try? c.decodeIfPresent([String].self, forKey: .usernames)
        uids = try? c.decodeIfPresent([String].self, forKey: .uids)
        ts = try? c.decodeIfPresent(Date.self, forKey: .ts)
        lm = try? c.decodeIfPresent(Date.self, forKey: .lm)
        lastMessage = try? c.decodeIfPresent(Message.self, forKey: .lastMessage)
        _updatedAt = try? c.decodeIfPresent(Date.self, forKey: ._updatedAt)
        prid = try? c.decodeIfPresent(String.self, forKey: .prid)
        teamId = try? c.decodeIfPresent(String.self, forKey: .teamId)
        archived = try? c.decodeIfPresent(Bool.self, forKey: .archived)
        encrypted = try? c.decodeIfPresent(Bool.self, forKey: .encrypted)
        broadcast = try? c.decodeIfPresent(Bool.self, forKey: .broadcast)
    }
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
    public var groupMentions: Int
    public var unreadThreads: Int
    public var favorite: Bool
    public var open: Bool
    public var readOnly: Bool
    public var lastMessage: Message? = nil
    public var lastActivity: Date? = nil
    /// When the user last saw the room (`ls`) — anchors the "new messages"
    /// separator.
    public var lastSeen: Date? = nil
    /// For a one-to-one DM: the other participant's user id (presence key).
    public var directPeerId: String? = nil

    public init(room: Room?, subscription: Subscription) {
        self.id = subscription.rid
        self.type = subscription.t ?? room?.t ?? .unknown
        self.displayName = subscription.fname ?? subscription.name
            ?? room?.fname ?? room?.name ?? subscription.rid
        self.topic = room?.topic
        self.unread = subscription.unread ?? 0
        self.alert = subscription.alert ?? false
        self.mentions = subscription.userMentions ?? 0
        self.groupMentions = subscription.groupMentions ?? 0
        self.unreadThreads = subscription.tunread?.count ?? 0
        self.favorite = subscription.f ?? false
        self.open = subscription.open ?? true
        self.readOnly = room?.ro ?? false
        self.lastMessage = room?.lastMessage
        self.lastActivity = room?.lm ?? room?.lastMessage?.ts ?? room?._updatedAt
        self.lastSeen = subscription.ls
        if self.type == .directMessage, let uids = room?.uids, uids.count == 2 {
            self.directPeerId = uids.first { $0 != subscription.u?._id }
        }
    }
}
