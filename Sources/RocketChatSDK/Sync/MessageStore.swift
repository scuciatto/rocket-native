import Foundation

/// Per-room message window store. In-memory and windowed in v1 — the window
/// is the SDK's main memory lever; a persistent cache can replace it behind
/// this protocol later.
public protocol MessageStoring: Sendable {
    func resetRoom(_ roomId: String, messages: [Message]) async
    func apply(delta: MessageDelta, in roomId: String) async
    func prepend(older: [Message], in roomId: String) async
    func insertPending(_ message: Message, in roomId: String) async
    func confirm(messageId: String, with message: Message?, in roomId: String) async
    func markFailed(messageId: String, in roomId: String) async
    func snapshot(_ roomId: String) async -> TimelineSnapshot
    func updates(_ roomId: String) async -> AsyncStream<TimelineSnapshot>
    func count(_ roomId: String) async -> Int
    func trim(_ roomId: String, to limit: Int) async
}

actor InMemoryMessageStore: MessageStoring {
    /// Cap applied when live deltas grow the window (scroll-back via
    /// `prepend` may exceed it up to `hardLimit`).
    private let windowLimit: Int
    private let hardLimit: Int

    private struct RoomTimeline {
        var byId: [String: Message] = [:]
        var pending: Set<String> = []
        var failed: Set<String> = []
    }

    private var timelines: [String: RoomTimeline] = [:]
    private var subscribers: [String: [UUID: AsyncStream<TimelineSnapshot>.Continuation]] = [:]

    init(windowLimit: Int = 200, hardLimit: Int = 1000) {
        self.windowLimit = windowLimit
        self.hardLimit = hardLimit
    }

    func resetRoom(_ roomId: String, messages: [Message]) {
        var timeline = RoomTimeline()
        for message in messages {
            timeline.byId[message._id] = message
        }
        timelines[roomId] = timeline
        broadcast(roomId)
    }

    func apply(delta: MessageDelta, in roomId: String) {
        var timeline = timelines[roomId] ?? RoomTimeline()
        for message in delta.updated {
            timeline.byId[message._id] = message
            // A server record for a pending id is the echo of an optimistic send.
            timeline.pending.remove(message._id)
            timeline.failed.remove(message._id)
        }
        for tombstone in delta.deleted {
            timeline.byId[tombstone._id] = nil
        }
        enforceWindow(&timeline, limit: windowLimit)
        timelines[roomId] = timeline
        broadcast(roomId)
    }

    func prepend(older: [Message], in roomId: String) {
        var timeline = timelines[roomId] ?? RoomTimeline()
        for message in older {
            timeline.byId[message._id] = message
        }
        enforceWindow(&timeline, limit: hardLimit)
        timelines[roomId] = timeline
        broadcast(roomId)
    }

    func insertPending(_ message: Message, in roomId: String) {
        var timeline = timelines[roomId] ?? RoomTimeline()
        timeline.byId[message._id] = message
        timeline.pending.insert(message._id)
        timelines[roomId] = timeline
        broadcast(roomId)
    }

    func confirm(messageId: String, with message: Message?, in roomId: String) {
        guard var timeline = timelines[roomId] else { return }
        if let message {
            timeline.byId[message._id] = message
        }
        timeline.pending.remove(messageId)
        timeline.failed.remove(messageId)
        timelines[roomId] = timeline
        broadcast(roomId)
    }

    func markFailed(messageId: String, in roomId: String) {
        guard var timeline = timelines[roomId] else { return }
        timeline.pending.remove(messageId)
        timeline.failed.insert(messageId)
        timelines[roomId] = timeline
        broadcast(roomId)
    }

    func snapshot(_ roomId: String) -> TimelineSnapshot {
        guard let timeline = timelines[roomId] else {
            return TimelineSnapshot(roomId: roomId, entries: [])
        }
        let entries = timeline.byId.values
            .sorted { ($0.ts, $0._id) < ($1.ts, $1._id) }
            .map { message in
                TimelineEntry(
                    message: message,
                    delivery: timeline.failed.contains(message._id) ? .failed
                        : timeline.pending.contains(message._id) ? .sending
                        : .sent)
            }
        return TimelineSnapshot(roomId: roomId, entries: entries)
    }

    func updates(_ roomId: String) -> AsyncStream<TimelineSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: TimelineSnapshot.self)
        let id = UUID()
        subscribers[roomId, default: [:]][id] = continuation
        continuation.yield(snapshot(roomId))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id, roomId: roomId) }
        }
        return stream
    }

    func count(_ roomId: String) -> Int {
        timelines[roomId]?.byId.count ?? 0
    }

    func trim(_ roomId: String, to limit: Int) {
        guard var timeline = timelines[roomId] else { return }
        enforceWindow(&timeline, limit: limit)
        timelines[roomId] = timeline
    }

    /// Drops the oldest messages beyond `limit`, never dropping unsent ones.
    private func enforceWindow(_ timeline: inout RoomTimeline, limit: Int) {
        let overflow = timeline.byId.count - limit
        guard overflow > 0 else { return }
        let droppable = timeline.byId.values
            .filter { !timeline.pending.contains($0._id) && !timeline.failed.contains($0._id) }
            .sorted { ($0.ts, $0._id) < ($1.ts, $1._id) }
            .prefix(overflow)
        for message in droppable {
            timeline.byId[message._id] = nil
        }
    }

    private func broadcast(_ roomId: String) {
        guard let continuations = subscribers[roomId], !continuations.isEmpty else { return }
        let current = snapshot(roomId)
        for continuation in continuations.values {
            continuation.yield(current)
        }
    }

    private func removeSubscriber(_ id: UUID, roomId: String) {
        subscribers[roomId]?[id] = nil
    }
}
