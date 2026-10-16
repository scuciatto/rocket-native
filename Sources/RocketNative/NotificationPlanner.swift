import Foundation
import RocketChatSDK

/// Decides which sidebar changes deserve a banner. One planner per account,
/// fed every room-list snapshot in order.
///
/// A banner needs two facts about a room: its unread/mention count grew
/// (from the *subscription* record) and its last message is new (from the
/// *room* record). A REST sidebar tick delivers both in one snapshot, but
/// the realtime stream delivers them as separate `subscriptions-changed` and
/// `rooms-changed` events, in either order, so each fact can land in its own
/// snapshot. Diffing consecutive snapshots therefore misses every message.
///
/// Instead the planner remembers, per room, the state it last *settled*
/// (announced, suppressed, or read): last message id plus unread and mention
/// counts. A room is announced once its current state shows both a last
/// message newer than the settled one and counts above the settled ones —
/// whichever snapshot completes the pair. Counts that drop (the user read
/// the room) lower the settled counts, so the next message counts as growth.
///
/// Known blind spot: someone else's last message that never raised the
/// unread count (e.g. a thread reply, a system message) stays unsettled; if
/// the room is later marked unread from another client, it is announced.
struct NotificationPlanner {
    struct Event: Equatable {
        var roomId: String
        var title: String
        var subtitle: String?
        var body: String
        var sound: Bool
    }

    /// What the planner last settled for a room.
    struct Settled: Equatable {
        var lastMessageId: String?
        var unread: Int
        var mentions: Int
    }

    private(set) var settled: [String: Settled] = [:]
    private var primed = false

    /// Feeds the next snapshot. `suppressedRoomId` is the room on screen
    /// (its account visible, app frontmost); it never notifies.
    mutating func ingest(
        _ rooms: [RoomSummary], suppressedRoomId: String?, selfUserId: String?
    ) -> [Event] {
        // The first snapshot is baseline state, not news.
        guard primed else {
            primed = true
            for room in rooms {
                settled[room.id] = Settled(room)
            }
            return []
        }
        var events: [Event] = []
        for room in rooms {
            // A room seen for the first time (e.g. a DM created by its first
            // message) starts from "nothing read, nothing announced".
            var state = settled[room.id] ?? Settled(lastMessageId: nil, unread: 0, mentions: 0)
            // Reading lowers the bar: the next message is growth again.
            state.unread = min(state.unread, room.unread)
            state.mentions = min(state.mentions, room.mentions)
            defer { settled[room.id] = state }

            // On screen: whatever is there has been seen.
            if room.id == suppressedRoomId {
                state = Settled(room)
                continue
            }
            guard let last = room.lastMessage, last.id != state.lastMessageId else { continue }
            // Own messages are never news; settle them so a later count
            // change can't pair with them.
            if last.u._id == selfUserId {
                state.lastMessageId = last.id
                continue
            }
            let unreadGrew = room.unread > state.unread
            let mentionsGrew = room.mentions > state.mentions
            // Half the pair: wait for the other record's snapshot.
            guard unreadGrew || mentionsGrew else { continue }

            state = Settled(room)
            events.append(Self.event(for: room, last: last, mentionsGrew: mentionsGrew))
        }
        return events
    }

    private static func event(for room: RoomSummary, last: Message, mentionsGrew: Bool) -> Event {
        let sender = last.u.name ?? last.u.username ?? "Someone"
        let text = last.msg.isEmpty
            ? "Sent an attachment"
            : String(EmojiMap.replacingShortcodes(in: last.msg).prefix(140))
        let isDirect = room.type == .directMessage
        return Event(
            roomId: room.id,
            title: isDirect ? sender : room.displayName,
            subtitle: isDirect ? nil : sender,
            body: text,
            sound: isDirect || mentionsGrew)
    }
}

extension NotificationPlanner.Settled {
    init(_ room: RoomSummary) {
        self.init(
            lastMessageId: room.lastMessage?.id, unread: room.unread, mentions: room.mentions)
    }
}
