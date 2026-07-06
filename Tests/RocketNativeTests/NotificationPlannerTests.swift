import Testing
import Foundation
@testable import RocketNative
@testable import RocketChatSDK

private func summary(
    id: String, type: RoomType = .channel, name: String? = nil,
    unread: Int = 0, mentions: Int = 0, alert: Bool = false,
    lastMessageId: String? = nil, lastText: String = "hello",
    senderId: String = "u-ana", senderName: String = "ana"
) -> RoomSummary {
    let room = Room(
        _id: id, t: type, name: name ?? id, fname: name ?? id,
        lastMessage: lastMessageId.map {
            Message(
                _id: $0, rid: id, msg: lastText,
                ts: Date(timeIntervalSince1970: 100),
                u: MiniUser(_id: senderId, username: senderName, name: senderName))
        })
    let subscription = Subscription(
        _id: "s-\(id)", rid: id, name: name ?? id, t: type,
        alert: alert, unread: unread, userMentions: mentions)
    return RoomSummary(room: room, subscription: subscription)
}

@MainActor
@Suite struct NotificationPlannerTests {
    @Test func newUnreadMessageNotifies() {
        let before = summary(id: "r1", unread: 0, lastMessageId: "m1")
        let after = summary(id: "r1", unread: 1, lastMessageId: "m2", lastText: "new one")
        let events = NotificationManager.plan(
            previous: ["r1": before], current: [after],
            suppressedRoomId: nil, selfUserId: "uid-9")
        #expect(events.count == 1)
        #expect(events[0].body == "new one")
        #expect(events[0].subtitle == "ana")
    }

    @Test func ownMessagesNeverNotify() {
        let before = summary(id: "r1", unread: 0, lastMessageId: "m1")
        let after = summary(
            id: "r1", unread: 1, lastMessageId: "m2", senderId: "uid-9")
        let events = NotificationManager.plan(
            previous: ["r1": before], current: [after],
            suppressedRoomId: nil, selfUserId: "uid-9")
        #expect(events.isEmpty)
    }

    @Test func visibleRoomIsSuppressed() {
        let before = summary(id: "r1", unread: 0, lastMessageId: "m1")
        let after = summary(id: "r1", unread: 1, lastMessageId: "m2")

        // Manager resolves "visible" (active account + app frontmost) into
        // suppressedRoomId; suppressed room stays silent, others don't.
        let visible = NotificationManager.plan(
            previous: ["r1": before], current: [after],
            suppressedRoomId: "r1", selfUserId: "uid-9")
        #expect(visible.isEmpty)

        let backgrounded = NotificationManager.plan(
            previous: ["r1": before], current: [after],
            suppressedRoomId: nil, selfUserId: "uid-9")
        #expect(backgrounded.count == 1)
    }

    @Test func readStateChurnWithoutNewMessageIsSilent() {
        // Unread grew but the last message is unchanged (e.g. mark-unread).
        let before = summary(id: "r1", unread: 0, lastMessageId: "m1")
        let after = summary(id: "r1", unread: 3, lastMessageId: "m1")
        let events = NotificationManager.plan(
            previous: ["r1": before], current: [after],
            suppressedRoomId: nil, selfUserId: "uid-9")
        #expect(events.isEmpty)
    }

    @Test func directMessagesUseSenderAsTitleAndSound() {
        let before = summary(id: "d1", type: .directMessage, unread: 0, lastMessageId: "m1")
        let after = summary(
            id: "d1", type: .directMessage, unread: 1, lastMessageId: "m2")
        let events = NotificationManager.plan(
            previous: ["d1": before], current: [after],
            suppressedRoomId: nil, selfUserId: "uid-9")
        #expect(events.count == 1)
        #expect(events[0].title == "ana")
        #expect(events[0].subtitle == nil)
        #expect(events[0].sound)
    }

    @Test func channelWithoutMentionIsSilentBanner() {
        let before = summary(id: "r1", unread: 0, lastMessageId: "m1")
        let after = summary(id: "r1", unread: 1, lastMessageId: "m2")
        let events = NotificationManager.plan(
            previous: ["r1": before], current: [after],
            suppressedRoomId: nil, selfUserId: "uid-9")
        #expect(events.count == 1)
        #expect(!events[0].sound)
    }
}

@MainActor
@Suite struct DockBadgeTests {
    @Test func personalCountWinsOverDot() {
        let rooms = [
            summary(id: "r1", unread: 5),                              // channel chatter
            summary(id: "r2", mentions: 2),                            // mentions
            summary(id: "d1", type: .directMessage, unread: 3),        // DM
        ]
        #expect(NotificationManager.dockBadgeLabel(accountRooms: [rooms]) == "5")
    }

    @Test func aggregatesAcrossServers() {
        let serverA = [summary(id: "d1", type: .directMessage, unread: 2)]
        let serverB = [summary(id: "r1", mentions: 1)]
        #expect(NotificationManager.dockBadgeLabel(
            accountRooms: [serverA, serverB]) == "3")
    }

    @Test func onlyChannelUnreadsShowDot() {
        let serverA = [summary(id: "r1", unread: 7)]
        let serverB = [summary(id: "r2")]
        #expect(NotificationManager.dockBadgeLabel(
            accountRooms: [serverA, serverB]) == "•")
    }

    @Test func allReadShowsNothing() {
        let rooms = [summary(id: "r1"), summary(id: "d1", type: .directMessage)]
        #expect(NotificationManager.dockBadgeLabel(accountRooms: [rooms]) == "")
    }
}

@MainActor
@Suite struct UnreadDividerTests {
    private func entry(_ id: String, ts: TimeInterval, sender: String = "u-ana") -> TimelineEntry {
        TimelineEntry(
            message: Message(
                _id: id, rid: "r1", msg: "hi",
                ts: Date(timeIntervalSince1970: ts),
                u: MiniUser(_id: sender, username: nil, name: nil)),
            delivery: .sent)
    }

    @Test func dividerLandsOnFirstForeignMessageAfterAnchor() {
        let entries = [
            entry("a", ts: 10), entry("b", ts: 20),
            entry("mine", ts: 30, sender: "uid-9"), entry("c", ts: 40),
        ]
        let id = TimelineList.firstUnreadId(
            entries: entries, anchor: Date(timeIntervalSince1970: 25),
            selfUserId: "uid-9")
        #expect(id == "c")   // skips own message at ts 30
    }

    @Test func noAnchorMeansNoDivider() {
        let entries = [entry("a", ts: 10)]
        #expect(TimelineList.firstUnreadId(
            entries: entries, anchor: nil, selfUserId: "uid-9") == nil)
    }

    @Test func allMessagesBeforeAnchorMeansNoDivider() {
        let entries = [entry("a", ts: 10), entry("b", ts: 20)]
        #expect(TimelineList.firstUnreadId(
            entries: entries, anchor: Date(timeIntervalSince1970: 99),
            selfUserId: "uid-9") == nil)
    }
}
