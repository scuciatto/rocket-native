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

/// Feeds `baseline` then each snapshot to a fresh planner; returns the
/// events produced per snapshot (after the baseline).
private func run(
    baseline: [RoomSummary], _ snapshots: [[RoomSummary]],
    suppressedRoomId: String? = nil, selfUserId: String = "uid-9"
) -> [[NotificationPlanner.Event]] {
    var planner = NotificationPlanner()
    _ = planner.ingest(baseline, suppressedRoomId: suppressedRoomId, selfUserId: selfUserId)
    return snapshots.map {
        planner.ingest($0, suppressedRoomId: suppressedRoomId, selfUserId: selfUserId)
    }
}

@MainActor
@Suite struct NotificationPlannerTests {
    @Test func firstSnapshotIsBaseline() {
        var planner = NotificationPlanner()
        let events = planner.ingest(
            [summary(id: "r1", unread: 5, lastMessageId: "m9")],
            suppressedRoomId: nil, selfUserId: "uid-9")
        #expect(events.isEmpty)
    }

    @Test func newUnreadMessageNotifies() {
        // REST tick: both facts in one snapshot.
        let events = run(
            baseline: [summary(id: "r1", unread: 0, lastMessageId: "m1")],
            [[summary(id: "r1", unread: 1, lastMessageId: "m2", lastText: "new one")]])
        #expect(events[0].count == 1)
        #expect(events[0].first?.body == "new one")
        #expect(events[0].first?.subtitle == "ana")
    }

    @Test func ownMessagesNeverNotify() {
        let events = run(
            baseline: [summary(id: "r1", unread: 0, lastMessageId: "m1")],
            [[summary(id: "r1", unread: 1, lastMessageId: "m2", senderId: "uid-9")]])
        #expect(events[0].isEmpty)
    }

    @Test func visibleRoomIsSuppressed() {
        let baseline = [summary(id: "r1", unread: 0, lastMessageId: "m1")]
        let after = [summary(id: "r1", unread: 1, lastMessageId: "m2")]
        #expect(run(baseline: baseline, [after], suppressedRoomId: "r1")[0].isEmpty)
        #expect(run(baseline: baseline, [after], suppressedRoomId: nil)[0].count == 1)
    }

    @Test func messageSeenOnScreenIsNotAnnouncedAfterLeaving() {
        var planner = NotificationPlanner()
        _ = planner.ingest(
            [summary(id: "r1", lastMessageId: "m1")], suppressedRoomId: "r1", selfUserId: "uid-9")
        _ = planner.ingest(
            [summary(id: "r1", unread: 1, lastMessageId: "m2")],
            suppressedRoomId: "r1", selfUserId: "uid-9")
        // User switches away; the same state must not become a banner.
        let events = planner.ingest(
            [summary(id: "r1", unread: 1, lastMessageId: "m2")],
            suppressedRoomId: nil, selfUserId: "uid-9")
        #expect(events.isEmpty)
    }

    @Test func readStateChurnWithoutNewMessageIsSilent() {
        // Unread grew but the last message is unchanged (e.g. mark-unread).
        let events = run(
            baseline: [summary(id: "r1", unread: 0, lastMessageId: "m1")],
            [[summary(id: "r1", unread: 3, lastMessageId: "m1")]])
        #expect(events[0].isEmpty)
    }

    @Test func directMessagesUseSenderAsTitleAndSound() {
        let events = run(
            baseline: [summary(id: "d1", type: .directMessage, unread: 0, lastMessageId: "m1")],
            [[summary(id: "d1", type: .directMessage, unread: 1, lastMessageId: "m2")]])
        #expect(events[0].count == 1)
        #expect(events[0].first?.title == "ana")
        #expect(events[0].first?.subtitle == nil)
        #expect(events[0].first?.sound == true)
    }

    @Test func channelWithoutMentionIsSilentBanner() {
        let events = run(
            baseline: [summary(id: "r1", unread: 0, lastMessageId: "m1")],
            [[summary(id: "r1", unread: 1, lastMessageId: "m2")]])
        #expect(events[0].count == 1)
        #expect(events[0].first?.sound == false)
    }

    @Test func mentionPlaysSound() {
        let events = run(
            baseline: [summary(id: "r1", lastMessageId: "m1")],
            [[summary(id: "r1", unread: 1, mentions: 1, lastMessageId: "m2")]])
        #expect(events[0].first?.sound == true)
    }

    // MARK: Realtime split snapshots (regression: no banners over the stream)

    /// The stream applies `subscriptions-changed` (counts) and
    /// `rooms-changed` (last message) as separate snapshots. Order observed
    /// on 8.6: subscription first.
    @Test func subscriptionFirstThenRoomNotifiesOnce() {
        let events = run(
            baseline: [summary(id: "d1", type: .directMessage, lastMessageId: "m1")],
            [
                [summary(id: "d1", type: .directMessage, unread: 1, lastMessageId: "m1")],
                [summary(id: "d1", type: .directMessage, unread: 1, lastMessageId: "m2")],
            ])
        #expect(events.map(\.count) == [0, 1])
        #expect(events[1].first?.roomId == "d1")
    }

    @Test func roomFirstThenSubscriptionNotifiesOnce() {
        let events = run(
            baseline: [summary(id: "r1", lastMessageId: "m1")],
            [
                [summary(id: "r1", unread: 0, lastMessageId: "m2", lastText: "split")],
                [summary(id: "r1", unread: 1, lastMessageId: "m2", lastText: "split")],
            ])
        #expect(events.map(\.count) == [0, 1])
        #expect(events[1].first?.body == "split")
    }

    @Test func newDirectMessageRoomArrivingInPiecesNotifies() {
        // First message from a new contact: the subscription can arrive
        // before the room record exists (no last message yet).
        let subscriptionOnly = RoomSummary(
            room: nil,
            subscription: Subscription(_id: "s-d9", rid: "d9", name: "zoe", t: .directMessage, unread: 1))
        let events = run(
            baseline: [summary(id: "r1", lastMessageId: "m1")],
            [
                [summary(id: "r1", lastMessageId: "m1"), subscriptionOnly],
                [summary(id: "r1", lastMessageId: "m1"),
                 summary(id: "d9", type: .directMessage, unread: 1, lastMessageId: "z1",
                         senderId: "u-zoe", senderName: "zoe")],
            ])
        #expect(events.map(\.count) == [0, 1])
        #expect(events[1].first?.title == "zoe")
    }

    @Test func eachMessageOfABurstNotifiesOnce() {
        // Two messages, records interleaved as captured from the server.
        let events = run(
            baseline: [summary(id: "d1", type: .directMessage, lastMessageId: "m0")],
            [
                [summary(id: "d1", type: .directMessage, unread: 1, lastMessageId: "m0")],
                [summary(id: "d1", type: .directMessage, unread: 1, lastMessageId: "m1")],
                [summary(id: "d1", type: .directMessage, unread: 2, lastMessageId: "m1")],
                [summary(id: "d1", type: .directMessage, unread: 2, lastMessageId: "m2")],
            ])
        #expect(events.map(\.count) == [0, 1, 0, 1])
    }

    @Test func repeatedStateFromRESTDoesNotRenotify() {
        // The safety-net REST tick re-delivers what the stream already applied.
        let announced = summary(id: "r1", unread: 1, lastMessageId: "m2")
        let events = run(
            baseline: [summary(id: "r1", lastMessageId: "m1")],
            [[announced], [announced], [announced]])
        #expect(events.map(\.count) == [1, 0, 0])
    }

    @Test func readingResetsSoTheNextMessageNotifies() {
        let events = run(
            baseline: [summary(id: "r1", lastMessageId: "m1")],
            [
                [summary(id: "r1", unread: 1, lastMessageId: "m2")],   // banner
                [summary(id: "r1", unread: 0, lastMessageId: "m2")],   // read elsewhere
                [summary(id: "r1", unread: 1, lastMessageId: "m2")],   // sub of next msg
                [summary(id: "r1", unread: 1, lastMessageId: "m3")],   // room of next msg
            ])
        #expect(events.map(\.count) == [1, 0, 0, 1])
    }

    @Test func ownMessageThenMarkUnreadIsSilent() {
        let events = run(
            baseline: [summary(id: "r1", lastMessageId: "m1")],
            [
                [summary(id: "r1", lastMessageId: "mine", senderId: "uid-9")],
                [summary(id: "r1", unread: 1, lastMessageId: "mine", senderId: "uid-9")],
            ])
        #expect(events.map(\.count) == [0, 0])
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
