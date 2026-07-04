import Foundation

/// Sidebar state store. In-memory in v1; the protocol is the seam where a
/// persistent (e.g. SQLite) cache can slot in later.
public protocol RoomStoring: Sendable {
    func apply(
        roomsUpdated: [Room], roomsRemoved: [String],
        subscriptionsUpdated: [Subscription], subscriptionsRemoved: [String]) async
    func snapshot() async -> [RoomSummary]
    func updates() async -> AsyncStream<[RoomSummary]>
    func roomType(_ roomId: String) async -> RoomType?
}

actor InMemoryRoomStore: RoomStoring {
    private var roomsById: [String: Room] = [:]
    private var subscriptionsByRoomId: [String: Subscription] = [:]
    private var subscribers: [UUID: AsyncStream<[RoomSummary]>.Continuation] = [:]

    func apply(
        roomsUpdated: [Room], roomsRemoved: [String],
        subscriptionsUpdated: [Subscription], subscriptionsRemoved: [String]
    ) {
        for room in roomsUpdated {
            roomsById[room._id] = room
        }
        for roomId in roomsRemoved {
            roomsById[roomId] = nil
        }
        for subscription in subscriptionsUpdated {
            subscriptionsByRoomId[subscription.rid] = subscription
        }
        for roomId in subscriptionsRemoved {
            subscriptionsByRoomId[roomId] = nil
        }
        guard !roomsUpdated.isEmpty || !roomsRemoved.isEmpty
            || !subscriptionsUpdated.isEmpty || !subscriptionsRemoved.isEmpty
        else { return }
        broadcast()
    }

    func snapshot() -> [RoomSummary] {
        subscriptionsByRoomId.values
            .map { RoomSummary(room: roomsById[$0.rid], subscription: $0) }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    func updates() -> AsyncStream<[RoomSummary]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [RoomSummary].self)
        let id = UUID()
        subscribers[id] = continuation
        continuation.yield(snapshot())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    func roomType(_ roomId: String) -> RoomType? {
        subscriptionsByRoomId[roomId]?.t ?? roomsById[roomId]?.t
    }

    private func broadcast() {
        let current = snapshot()
        for continuation in subscribers.values {
            continuation.yield(current)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}
