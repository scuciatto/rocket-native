import Foundation

/// SQLite-backed `RoomStoring`. Rows are the wire JSON of each record —
/// schema-light on purpose (the server's shapes drift; we never migrate
/// individual columns). An in-memory mirror is loaded once so reads cost the
/// same as the in-memory store; SQLite is the durable copy.
actor SQLiteRoomStore: RoomStoring {
    private let database: SQLiteDatabase
    private let encoder = RCJSON.encoder()
    private let decoder = RCJSON.decoder()

    private var loaded = false
    private var roomsById: [String: Room] = [:]
    private var subscriptionsByRoomId: [String: Subscription] = [:]
    private var subscribers: [UUID: AsyncStream<[RoomSummary]>.Continuation] = [:]

    init(path: String) throws {
        database = try SQLiteDatabase(path: path)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS rooms (
                id TEXT PRIMARY KEY,
                json TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS subscriptions (
                rid TEXT PRIMARY KEY,
                json TEXT NOT NULL
            );
            """)
    }

    func apply(
        roomsUpdated: [Room], roomsRemoved: [String],
        subscriptionsUpdated: [Subscription], subscriptionsRemoved: [String]
    ) {
        ensureLoaded()
        for room in roomsUpdated {
            roomsById[room._id] = room
            if let json = encodeJSON(room) {
                try? database.run(
                    "INSERT INTO rooms (id, json) VALUES (?, ?) "
                    + "ON CONFLICT(id) DO UPDATE SET json = excluded.json",
                    [.text(room._id), .text(json)])
            }
        }
        for roomId in roomsRemoved {
            roomsById[roomId] = nil
            try? database.run("DELETE FROM rooms WHERE id = ?", [.text(roomId)])
        }
        for subscription in subscriptionsUpdated {
            subscriptionsByRoomId[subscription.rid] = subscription
            if let json = encodeJSON(subscription) {
                try? database.run(
                    "INSERT INTO subscriptions (rid, json) VALUES (?, ?) "
                    + "ON CONFLICT(rid) DO UPDATE SET json = excluded.json",
                    [.text(subscription.rid), .text(json)])
            }
        }
        for roomId in subscriptionsRemoved {
            subscriptionsByRoomId[roomId] = nil
            try? database.run("DELETE FROM subscriptions WHERE rid = ?", [.text(roomId)])
        }
        guard !roomsUpdated.isEmpty || !roomsRemoved.isEmpty
            || !subscriptionsUpdated.isEmpty || !subscriptionsRemoved.isEmpty
        else { return }
        broadcast()
    }

    func snapshot() -> [RoomSummary] {
        ensureLoaded()
        return subscriptionsByRoomId.values
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
        ensureLoaded()
        return subscriptionsByRoomId[roomId]?.t ?? roomsById[roomId]?.t
    }

    // MARK: - Internals

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        let roomRows = (try? database.query("SELECT json FROM rooms") { column in
            column(0).textValue
        }) ?? []
        for json in roomRows {
            if let room: Room = decodeJSON(json) {
                roomsById[room._id] = room
            }
        }
        let subscriptionRows = (try? database.query("SELECT json FROM subscriptions") { column in
            column(0).textValue
        }) ?? []
        for json in subscriptionRows {
            if let subscription: Subscription = decodeJSON(json) {
                subscriptionsByRoomId[subscription.rid] = subscription
            }
        }
    }

    private func encodeJSON(_ value: some Encodable) -> String? {
        (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func decodeJSON<T: Decodable>(_ json: String?) -> T? {
        guard let json else { return nil }
        return try? decoder.decode(T.self, from: Data(json.utf8))
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
