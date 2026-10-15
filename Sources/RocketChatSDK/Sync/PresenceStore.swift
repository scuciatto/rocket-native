import Foundation

/// Last known presence per user id, fed by REST `users.presence` seeds and
/// `stream-user-presence` events. Snapshots are whole maps; the set of
/// tracked users is small (DM partners), so that stays cheap.
actor PresenceStore {
    private var byUserId: [String: UserPresence] = [:]
    private var subscribers: [UUID: AsyncStream<[String: UserPresence]>.Continuation] = [:]

    func apply(_ updates: [UserPresence]) {
        var changed = false
        for presence in updates where byUserId[presence.userId] != presence {
            byUserId[presence.userId] = presence
            changed = true
        }
        if changed {
            broadcast()
        }
    }

    func snapshot() -> [String: UserPresence] {
        byUserId
    }

    func updates() -> AsyncStream<[String: UserPresence]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [String: UserPresence].self)
        let id = UUID()
        subscribers[id] = continuation
        continuation.yield(byUserId)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func broadcast() {
        for continuation in subscribers.values {
            continuation.yield(byUserId)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}
