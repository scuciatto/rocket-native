import Foundation

/// The live-update mechanism of this REST-only SDK: tiered adaptive polling
/// of the delta endpoints.
///
/// - Sidebar tier: `subscriptions.get` + `rooms.get` with `updatedSince`
///   (2 requests/tick) keeps unread counts and previews fresh workspace-wide.
/// - Room tier: `chat.syncMessages` with `lastUpdate` (1 request/tick) delivers
///   inserts, edits, and deletions for each open room.
///
/// High-water marks come from server record timestamps (`_updatedAt`), never
/// the client clock, so ticks are also the recovery path after sleep or
/// network loss — no special reconnect logic exists or is needed.
actor SyncEngine {
    struct Config: Sendable {
        var sidebarActiveInterval: TimeInterval = 15
        var sidebarIdleInterval: TimeInterval = 60
        var roomActiveInterval: TimeInterval = 2.5
        var roomIdleInterval: TimeInterval = 10
        var pageSize: Int = 50
        var closedRoomWindowLimit: Int = 50
    }

    private let rest: RESTClient
    private let auth: AuthSession
    private let clock: RESTClock
    private let config: Config
    let roomStore: RoomStoring
    let messageStore: MessageStoring

    private var appActive = true
    private var sidebarTask: Task<Void, Never>?
    private var roomTasks: [String: Task<Void, Never>] = [:]

    private var roomsHighWater: Date?
    private var subscriptionsHighWater: Date?
    private var roomHighWater: [String: Date] = [:]

    private var state: SyncState = .idle
    private var consecutiveFailures = 0
    private var stateSubscribers: [UUID: AsyncStream<SyncState>.Continuation] = [:]

    init(
        rest: RESTClient,
        auth: AuthSession,
        clock: RESTClock,
        config: Config = Config(),
        roomStore: RoomStoring = InMemoryRoomStore(),
        messageStore: MessageStoring = InMemoryMessageStore()
    ) {
        self.rest = rest
        self.auth = auth
        self.clock = clock
        self.config = config
        self.roomStore = roomStore
        self.messageStore = messageStore
    }

    // MARK: - Lifecycle

    func start() async {
        guard sidebarTask == nil else { return }
        setState(.syncing)
        await tickSidebar()
        sidebarTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await self.sidebarInterval
                try? await self.clock.sleep(seconds: interval)
                if Task.isCancelled { return }
                await self.tickSidebar()
            }
        }
    }

    func stop() {
        sidebarTask?.cancel()
        sidebarTask = nil
        for task in roomTasks.values {
            task.cancel()
        }
        roomTasks = [:]
        setState(.idle)
    }

    /// Background/occluded apps poll slower; call on NSApplication state changes.
    /// Activation also fires an immediate catch-up tick.
    func setAppActive(_ active: Bool) async {
        let wasActive = appActive
        appActive = active
        if active, !wasActive, sidebarTask != nil {
            await tickSidebar()
            for roomId in roomTasks.keys {
                await tickRoom(roomId)
            }
        }
    }

    // MARK: - Sidebar tier

    func tickSidebar() async {
        do {
            async let roomsDelta = rest.send(API.Rooms.get(updatedSince: roomsHighWater))
            async let subscriptionsDelta = rest.send(
                API.Subscriptions.get(updatedSince: subscriptionsHighWater))
            let rooms = try await roomsDelta
            let subscriptions = try await subscriptionsDelta

            advance(&roomsHighWater, past: rooms.update.compactMap(\._updatedAt))
            advance(&roomsHighWater, past: (rooms.remove ?? []).compactMap(\._updatedAt))
            advance(&subscriptionsHighWater, past: subscriptions.update.compactMap(\._updatedAt))
            advance(&subscriptionsHighWater, past: (subscriptions.remove ?? []).compactMap(\._updatedAt))

            await roomStore.apply(
                roomsUpdated: rooms.update,
                roomsRemoved: (rooms.remove ?? []).map(\._id),
                subscriptionsUpdated: subscriptions.update,
                subscriptionsRemoved: (subscriptions.remove ?? []).map(\.rid))
            noteTickSuccess()
        } catch {
            noteTickFailure(error)
        }
    }

    // MARK: - Room tier

    /// Loads the newest page and starts the fast poll loop for a room.
    func openRoom(_ roomId: String, startPolling: Bool = true) async throws {
        guard roomTasks[roomId] == nil else { return }
        try await initialLoad(roomId)
        guard startPolling else { return }
        roomTasks[roomId] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await self.roomInterval
                try? await self.clock.sleep(seconds: interval)
                if Task.isCancelled { return }
                await self.tickRoom(roomId)
            }
        }
    }

    func closeRoom(_ roomId: String) async {
        roomTasks[roomId]?.cancel()
        roomTasks[roomId] = nil
        roomHighWater[roomId] = nil
        await messageStore.trim(roomId, to: config.closedRoomWindowLimit)
    }

    private func initialLoad(_ roomId: String) async throws {
        let type = await roomStore.roomType(roomId) ?? .channel
        let page = try await rest.send(API.roomMessages(
            roomId: roomId, type: type, count: config.pageSize, offset: 0))
        await messageStore.resetRoom(roomId, messages: page.messages)
        var highWater: Date?
        advance(&highWater, past: page.messages.map { $0._updatedAt ?? $0.ts })
        roomHighWater[roomId] = highWater ?? clock.now
    }

    func tickRoom(_ roomId: String) async {
        guard let since = roomHighWater[roomId] else { return }
        do {
            let response = try await rest.send(
                API.Chat.syncMessages(roomId: roomId, lastUpdate: since))
            let delta = MessageDelta(
                updated: response.result.updated,
                deleted: response.result.deleted ?? [])
            var highWater: Date? = since
            advance(&highWater, past: delta.updated.map { $0._updatedAt ?? $0.ts })
            advance(&highWater, past: delta.deleted.compactMap(\._deletedAt))
            roomHighWater[roomId] = highWater
            if !delta.updated.isEmpty || !delta.deleted.isEmpty {
                await messageStore.apply(delta: delta, in: roomId)
            }
            noteTickSuccess()
        } catch {
            noteTickFailure(error)
        }
    }

    /// Older-history paging: offset past what the window already holds.
    func loadOlder(_ roomId: String) async throws {
        let type = await roomStore.roomType(roomId) ?? .channel
        let offset = await messageStore.count(roomId)
        let page = try await rest.send(API.roomMessages(
            roomId: roomId, type: type, count: config.pageSize, offset: offset))
        await messageStore.prepend(older: page.messages, in: roomId)
    }

    // MARK: - Sending (optimistic)

    func send(text: String, roomId: String, threadId: String? = nil) async throws {
        let messageId = MessageID.generate()
        let author = await auth.miniUser
        let optimistic = Message(
            _id: messageId, rid: roomId, msg: text,
            ts: clock.now, u: author, tmid: threadId)
        await messageStore.insertPending(optimistic, in: roomId)
        do {
            let sent = try await rest.send(API.Chat.sendMessage(
                roomId: roomId, text: text, messageId: messageId, threadId: threadId))
            await messageStore.confirm(
                messageId: messageId, with: sent.message, in: roomId)
            // A message of ours means an active conversation; catch up now
            // rather than waiting out the poll interval.
            await tickRoom(roomId)
        } catch {
            await messageStore.markFailed(messageId: messageId, in: roomId)
            throw error
        }
    }

    // MARK: - State

    func stateUpdates() -> AsyncStream<SyncState> {
        let (stream, continuation) = AsyncStream.makeStream(of: SyncState.self)
        let id = UUID()
        stateSubscribers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateSubscriber(id) }
        }
        return stream
    }

    private func noteTickSuccess() {
        consecutiveFailures = 0
        setState(.synced)
    }

    private func noteTickFailure(_ error: Error) {
        if case RocketChatError.notAuthenticated = error {
            setState(.unauthorized)
            return
        }
        consecutiveFailures += 1
        if consecutiveFailures >= 2 {
            setState(.degraded)
        }
    }

    private func setState(_ newState: SyncState) {
        guard newState != state else { return }
        state = newState
        for continuation in stateSubscribers.values {
            continuation.yield(newState)
        }
    }

    private func removeStateSubscriber(_ id: UUID) {
        stateSubscribers[id] = nil
    }

    // MARK: - Helpers

    private var sidebarInterval: TimeInterval {
        appActive ? config.sidebarActiveInterval : config.sidebarIdleInterval
    }

    private var roomInterval: TimeInterval {
        appActive ? config.roomActiveInterval : config.roomIdleInterval
    }

    private func advance(_ mark: inout Date?, past dates: [Date]) {
        guard let newest = dates.max() else { return }
        if mark.map({ newest > $0 }) ?? true {
            mark = newest
        }
    }
}
