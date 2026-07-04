import Foundation

/// SQLite-backed `MessageStoring`. History accumulates durably; the UI-facing
/// snapshot stays windowed via a per-window *visible limit* (grown by
/// `prepend`, shrunk by `trim`), so memory behavior matches the in-memory
/// store while scroll-back and cold launches hit the local cache.
///
/// Rows are keyed by `(window, id)`: the store's "roomId" parameter is a
/// window key — a room id for room timelines, `thread/<tmid>` for thread
/// panels — and one message may legitimately appear in both.
///
/// Unsent (`pending`) rows from a previous run are demoted to `failed` at
/// load — an optimistic send that never confirmed must not show as
/// "sending" forever.
actor SQLiteMessageStore: MessageStoring {
    private let database: SQLiteDatabase
    private let encoder = RCJSON.encoder()
    private let decoder = RCJSON.decoder()
    private let defaultWindowLimit: Int

    private var loaded = false
    private var visibleLimits: [String: Int] = [:]
    private var subscribers: [String: [UUID: AsyncStream<TimelineSnapshot>.Continuation]] = [:]

    init(path: String, windowLimit: Int = 200) throws {
        database = try SQLiteDatabase(path: path)
        defaultWindowLimit = windowLimit
        try database.execute("""
            CREATE TABLE IF NOT EXISTS messages (
                window TEXT NOT NULL,
                id TEXT NOT NULL,
                ts REAL NOT NULL,
                pending INTEGER NOT NULL DEFAULT 0,
                failed INTEGER NOT NULL DEFAULT 0,
                json TEXT NOT NULL,
                PRIMARY KEY (window, id)
            );
            CREATE INDEX IF NOT EXISTS idx_messages_window_ts ON messages(window, ts);
            """)
    }

    func resetRoom(_ roomId: String, messages: [Message]) {
        ensureLoaded()
        try? database.run("DELETE FROM messages WHERE window = ?", [.text(roomId)])
        for message in messages {
            upsert(message, in: roomId)
        }
        visibleLimits[roomId] = defaultWindowLimit
        broadcast(roomId)
    }

    func apply(delta: MessageDelta, in roomId: String) {
        ensureLoaded()
        for message in delta.updated {
            upsert(message, in: roomId)
        }
        for tombstone in delta.deleted {
            try? database.run(
                "DELETE FROM messages WHERE window = ? AND id = ?",
                [.text(roomId), .text(tombstone._id)])
        }
        broadcast(roomId)
    }

    func prepend(older: [Message], in roomId: String) {
        ensureLoaded()
        for message in older {
            upsert(message, in: roomId)
        }
        // Scroll-back widens what the snapshot exposes.
        visibleLimits[roomId] = currentLimit(roomId) + older.count
        broadcast(roomId)
    }

    func insertPending(_ message: Message, in roomId: String) {
        ensureLoaded()
        upsert(message, in: roomId, pending: true)
        broadcast(roomId)
    }

    func confirm(messageId: String, with message: Message?, in roomId: String) {
        ensureLoaded()
        if let message {
            upsert(message, in: roomId)
        } else {
            try? database.run(
                "UPDATE messages SET pending = 0, failed = 0 WHERE window = ? AND id = ?",
                [.text(roomId), .text(messageId)])
        }
        broadcast(roomId)
    }

    func markFailed(messageId: String, in roomId: String) {
        ensureLoaded()
        try? database.run(
            "UPDATE messages SET pending = 0, failed = 1 WHERE window = ? AND id = ?",
            [.text(roomId), .text(messageId)])
        broadcast(roomId)
    }

    func snapshot(_ roomId: String) -> TimelineSnapshot {
        ensureLoaded()
        let limit = currentLimit(roomId)
        // Newest `limit` rows, plus any unsent rows regardless of age.
        let rows = (try? database.query("""
            SELECT json, pending, failed FROM messages
            WHERE window = ?1 AND (
                id IN (SELECT id FROM messages WHERE window = ?1 ORDER BY ts DESC LIMIT ?2)
                OR pending = 1 OR failed = 1)
            ORDER BY ts ASC, id ASC
            """, [.text(roomId), .int(Int64(limit))]) { column in
            (column(0).textValue, column(1).intValue, column(2).intValue)
        }) ?? []

        let entries: [TimelineEntry] = rows.compactMap { json, pending, failed in
            guard let json,
                  let message = try? decoder.decode(Message.self, from: Data(json.utf8))
            else { return nil }
            let delivery: DeliveryState = failed == 1 ? .failed
                : pending == 1 ? .sending : .sent
            return TimelineEntry(message: message, delivery: delivery)
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

    /// Total cached messages in a window — drives `loadOlder` offset paging.
    func count(_ roomId: String) -> Int {
        ensureLoaded()
        let rows = (try? database.query(
            "SELECT COUNT(*) FROM messages WHERE window = ?", [.text(roomId)]
        ) { column in column(0).intValue }) ?? []
        return Int(rows.first.flatMap { $0 } ?? 0)
    }

    /// Shrinks the *visible window* only — cached history stays on disk.
    func trim(_ roomId: String, to limit: Int) {
        visibleLimits[roomId] = max(limit, 0)
    }

    // MARK: - Internals

    private func currentLimit(_ roomId: String) -> Int {
        max(visibleLimits[roomId] ?? defaultWindowLimit, 1)
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        // Unconfirmed optimistic sends from a previous run → failed.
        try? database.run("UPDATE messages SET pending = 0, failed = 1 WHERE pending = 1")
    }

    private func upsert(_ message: Message, in window: String, pending: Bool = false) {
        guard let data = try? encoder.encode(message),
              let json = String(data: data, encoding: .utf8) else { return }
        try? database.run("""
            INSERT INTO messages (window, id, ts, pending, failed, json)
            VALUES (?, ?, ?, ?, 0, ?)
            ON CONFLICT(window, id) DO UPDATE SET
                ts = excluded.ts, json = excluded.json,
                pending = excluded.pending, failed = 0
            """, [
                .text(window), .text(message._id),
                .real(message.ts.timeIntervalSince1970),
                .int(pending ? 1 : 0), .text(json),
            ])
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
