import Foundation

/// A live view into one thread, mirroring `RoomHandle`. Obtain via
/// `RocketChatClient.openThread(_:in:)`; `close()` when the panel closes.
public final class ThreadHandle: Sendable {
    public let threadId: String
    public let roomId: String
    private let engine: SyncEngine

    init(threadId: String, roomId: String, engine: SyncEngine) {
        self.threadId = threadId
        self.roomId = roomId
        self.engine = engine
    }

    /// Snapshots of the thread's replies, oldest first.
    public func timelineUpdates() async -> AsyncStream<TimelineSnapshot> {
        await engine.messageStore.updates(SyncEngine.threadKey(threadId))
    }

    public func timeline() async -> TimelineSnapshot {
        await engine.messageStore.snapshot(SyncEngine.threadKey(threadId))
    }

    /// Sends a reply into the thread (optimistic, like `RoomHandle.send`).
    public func send(text: String) async throws {
        try await engine.send(text: text, roomId: roomId, threadId: threadId)
    }

    public func close() async {
        await engine.closeThread(threadId)
    }
}
