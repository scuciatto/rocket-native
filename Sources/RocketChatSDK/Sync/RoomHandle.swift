import Foundation

/// A live view into one room: the message window plus the fast poll loop
/// that keeps it fresh. Obtain via `RocketChatClient.openRoom(_:)`; call
/// `close()` when the room leaves the screen so polling stops and the
/// window shrinks.
public final class RoomHandle: Sendable {
    public let roomId: String
    private let engine: SyncEngine
    private let client: RocketChatClient

    init(roomId: String, engine: SyncEngine, client: RocketChatClient) {
        self.roomId = roomId
        self.engine = engine
        self.client = client
    }

    /// Snapshots of the message window, oldest first. Yields the current
    /// window immediately, then on every change.
    public func timelineUpdates() async -> AsyncStream<TimelineSnapshot> {
        await engine.messageStore.updates(roomId)
    }

    public func timeline() async -> TimelineSnapshot {
        await engine.messageStore.snapshot(roomId)
    }

    /// Pages older history into the window.
    public func loadOlder() async throws {
        try await engine.loadOlder(roomId)
    }

    /// Sends optimistically: the message appears in the timeline as
    /// `.sending` immediately and reconciles with the server echo.
    public func send(text: String, threadId: String? = nil) async throws {
        try await engine.send(text: text, roomId: roomId, threadId: threadId)
    }

    public func markRead() async throws {
        try await client.markRead(roomId: roomId)
    }

    public func close() async {
        await engine.closeRoom(roomId)
    }
}
