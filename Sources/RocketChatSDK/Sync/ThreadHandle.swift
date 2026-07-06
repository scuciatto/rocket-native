import Foundation

/// A live view into one thread, mirroring `RoomHandle`. Obtain via
/// `RocketChatClient.openThread(_:in:)`; `close()` when the panel closes.
public final class ThreadHandle: Sendable {
    public let threadId: String
    public let roomId: String
    private let engine: SyncEngine
    private let client: RocketChatClient

    init(threadId: String, roomId: String, engine: SyncEngine, client: RocketChatClient) {
        self.threadId = threadId
        self.roomId = roomId
        self.engine = engine
        self.client = client
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

    /// Toggles a reaction on a thread message, catching up immediately.
    public func react(messageId: String, emoji: String, on: Bool? = nil) async throws {
        try await client.react(messageId: messageId, emoji: emoji, on: on)
        await engine.tickThread(threadId)
    }

    /// Edits a thread message and catches up immediately.
    public func edit(messageId: String, text: String) async throws {
        _ = try await client.edit(messageId: messageId, roomId: roomId, text: text)
        await engine.tickThread(threadId)
    }

    /// Deletes a thread message and catches up immediately.
    public func delete(messageId: String) async throws {
        try await client.delete(messageId: messageId, roomId: roomId)
        await engine.tickThread(threadId)
    }

    /// Uploads a file as a thread reply and catches up immediately.
    @discardableResult
    public func upload(
        _ file: UploadableFile, text: String? = nil, description: String? = nil
    ) async throws -> Message? {
        let message = try await client.uploadFile(
            file, roomId: roomId, text: text, description: description,
            threadId: threadId)
        await engine.tickThread(threadId)
        return message
    }

    public func close() async {
        await engine.closeThread(threadId)
    }
}
