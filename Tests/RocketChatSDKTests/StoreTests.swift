import Testing
import Foundation
@testable import RocketChatSDK

private func msg(
    _ id: String, ts: TimeInterval, text: String = "hi",
    updatedAt: TimeInterval? = nil, user: String = "ana"
) -> Message {
    Message(
        _id: id, rid: "room-1", msg: text,
        ts: Date(timeIntervalSince1970: ts),
        u: MiniUser(_id: "u-\(user)", username: user, name: nil),
        _updatedAt: updatedAt.map(Date.init(timeIntervalSince1970:)))
}

@Suite struct MessageStoreTests {
    @Test func applyUpsertsAndDeletes() async {
        let store = InMemoryMessageStore()
        await store.resetRoom("room-1", messages: [msg("a", ts: 1), msg("b", ts: 2)])
        await store.apply(
            delta: MessageDelta(
                updated: [msg("b", ts: 2, text: "edited"), msg("c", ts: 3)],
                deleted: [DeletedMessage(_id: "a", _deletedAt: nil)]),
            in: "room-1")

        let snapshot = await store.snapshot("room-1")
        #expect(snapshot.entries.map(\.id) == ["b", "c"])
        #expect(snapshot.entries[0].message.msg == "edited")
        #expect(snapshot.entries.allSatisfy { $0.delivery == .sent })
    }

    @Test func optimisticSendLifecycle() async {
        let store = InMemoryMessageStore()
        await store.resetRoom("room-1", messages: [msg("a", ts: 1)])

        await store.insertPending(msg("local-1", ts: 5, user: "felipe"), in: "room-1")
        var snapshot = await store.snapshot("room-1")
        #expect(snapshot.entries.last?.delivery == .sending)

        // Server delta echoing the same id flips it to sent.
        await store.apply(
            delta: MessageDelta(updated: [msg("local-1", ts: 5, user: "felipe")], deleted: []),
            in: "room-1")
        snapshot = await store.snapshot("room-1")
        #expect(snapshot.entries.last?.delivery == .sent)
    }

    @Test func failedSendIsMarkedAndSurvivesWindowTrim() async {
        let store = InMemoryMessageStore(windowLimit: 3, hardLimit: 5)
        await store.insertPending(msg("failing", ts: 0, user: "felipe"), in: "room-1")
        await store.markFailed(messageId: "failing", in: "room-1")

        // Flood the window: oldest sent messages get dropped, failed stays.
        await store.apply(
            delta: MessageDelta(
                updated: (1...6).map { msg("m\($0)", ts: TimeInterval($0)) },
                deleted: []),
            in: "room-1")

        let snapshot = await store.snapshot("room-1")
        #expect(snapshot.entries.count == 3)
        #expect(snapshot.entries.contains { $0.id == "failing" && $0.delivery == .failed })
    }

    @Test func updatesStreamYieldsCurrentThenChanges() async {
        let store = InMemoryMessageStore()
        await store.resetRoom("room-1", messages: [msg("a", ts: 1)])

        let stream = await store.updates("room-1")
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.entries.map(\.id) == ["a"])

        await store.apply(
            delta: MessageDelta(updated: [msg("b", ts: 2)], deleted: []), in: "room-1")
        let second = await iterator.next()
        #expect(second?.entries.map(\.id) == ["a", "b"])
    }
}

@Suite struct RoomStoreTests {
    @Test func joinsAndRemoves() async {
        let store = InMemoryRoomStore()
        let room = Room(_id: "r1", t: .channel, name: "general")
        let sub = Subscription(_id: "s1", rid: "r1", name: "general", t: .channel, unread: 2)

        await store.apply(
            roomsUpdated: [room], roomsRemoved: [],
            subscriptionsUpdated: [sub], subscriptionsRemoved: [])
        var list = await store.snapshot()
        #expect(list.count == 1)
        #expect(list[0].unread == 2)
        #expect(await store.roomType("r1") == .channel)

        await store.apply(
            roomsUpdated: [], roomsRemoved: [],
            subscriptionsUpdated: [], subscriptionsRemoved: ["r1"])
        list = await store.snapshot()
        #expect(list.isEmpty)
    }
}
