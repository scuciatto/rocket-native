import Foundation

/// Who is typing where, from `<rid>/user-activity` stream events. Keyed by
/// room plus optional thread, so the room timeline and a thread panel show
/// only their own typists.
///
/// Entries expire after `ttl` unless refreshed: senders repeat "typing" every
/// few seconds while active, so a lost "stopped" event (or a sender that
/// disconnected mid-word) can't leave someone typing forever.
actor TypingTracker {
    struct Key: Hashable {
        var roomId: String
        var threadId: String?
    }

    private let clock: RESTClock
    private let ttl: TimeInterval

    /// Typist name → expiry, per key. Dictionary order isn't stable, so
    /// snapshots sort by first-seen order kept in `order`.
    private var expiries: [Key: [String: Date]] = [:]
    private var order: [Key: [String]] = [:]
    private var expiryTasks: [Key: Task<Void, Never>] = [:]
    private var subscribers: [Key: [UUID: AsyncStream<[String]>.Continuation]] = [:]

    init(clock: RESTClock, ttl: TimeInterval = 10) {
        self.clock = clock
        self.ttl = ttl
    }

    func apply(roomId: String, threadId: String?, name: String, active: Bool) {
        let key = Key(roomId: roomId, threadId: threadId)
        let before = typists(key)
        if active {
            expiries[key, default: [:]][name] = clock.now.addingTimeInterval(ttl)
            if !(order[key]?.contains(name) ?? false) {
                order[key, default: []].append(name)
            }
            scheduleExpiry(key)
        } else {
            remove(name, from: key)
        }
        if typists(key) != before {
            broadcast(key)
        }
    }

    /// Clears a room (and its threads), e.g. when it closes.
    func clear(roomId: String) {
        for key in Array(expiries.keys) where key.roomId == roomId {
            clear(key)
        }
    }

    /// Clears everything, e.g. when the socket drops (no stops will arrive).
    func clearAll() {
        for key in Array(expiries.keys) {
            clear(key)
        }
    }

    func typists(roomId: String, threadId: String?) -> [String] {
        typists(Key(roomId: roomId, threadId: threadId))
    }

    func updates(roomId: String, threadId: String?) -> AsyncStream<[String]> {
        let key = Key(roomId: roomId, threadId: threadId)
        let (stream, continuation) = AsyncStream.makeStream(of: [String].self)
        let id = UUID()
        subscribers[key, default: [:]][id] = continuation
        continuation.yield(typists(key))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id, key: key) }
        }
        return stream
    }

    // MARK: - Internals

    private func typists(_ key: Key) -> [String] {
        let live = expiries[key] ?? [:]
        return (order[key] ?? []).filter { live[$0] != nil }
    }

    private func remove(_ name: String, from key: Key) {
        expiries[key]?[name] = nil
        order[key]?.removeAll { $0 == name }
        if expiries[key]?.isEmpty ?? false {
            expiries[key] = nil
            order[key] = nil
            expiryTasks.removeValue(forKey: key)?.cancel()
        }
    }

    private func clear(_ key: Key) {
        let hadTypists = !typists(key).isEmpty
        expiries[key] = nil
        order[key] = nil
        expiryTasks.removeValue(forKey: key)?.cancel()
        if hadTypists {
            broadcast(key)
        }
    }

    /// One timer per key, aimed at the soonest expiry; re-armed on refresh.
    private func scheduleExpiry(_ key: Key) {
        expiryTasks[key]?.cancel()
        guard let soonest = expiries[key]?.values.min() else { return }
        let delay = max(soonest.timeIntervalSince(clock.now), 0)
        expiryTasks[key] = Task { [weak self, clock] in
            try? await clock.sleep(seconds: delay)
            guard !Task.isCancelled else { return }
            await self?.expire(key)
        }
    }

    private func expire(_ key: Key) {
        let now = clock.now
        let before = typists(key)
        for (name, expiry) in expiries[key] ?? [:] where expiry <= now {
            remove(name, from: key)
        }
        if expiries[key] != nil {
            scheduleExpiry(key)
        }
        if typists(key) != before {
            broadcast(key)
        }
    }

    private func broadcast(_ key: Key) {
        guard let continuations = subscribers[key] else { return }
        let current = typists(key)
        for continuation in continuations.values {
            continuation.yield(current)
        }
    }

    private func removeSubscriber(_ id: UUID, key: Key) {
        subscribers[key]?[id] = nil
    }
}
