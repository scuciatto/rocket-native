import Foundation

/// The live-update mechanism and source of truth: tiered adaptive polling of
/// the REST delta endpoints. Push signals only accelerate it.
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
        /// Deepest a jump-to-message may grow the window (matches the
        /// in-memory store's hard limit, past which prepends are dropped).
        var jumpWindowLimit: Int = 1000
    }

    private let rest: RESTClient
    private let auth: AuthSession
    private let clock: RESTClock
    private let config: Config
    let roomStore: RoomStoring
    let messageStore: MessageStoring
    let markStore: SyncMarkStoring

    private var appActive = true
    private var sidebarTask: Task<Void, Never>?
    private var roomTasks: [String: Task<Void, Never>] = [:]
    private var threadTasks: [String: Task<Void, Never>] = [:]

    private var roomsHighWater: Date?
    private var subscriptionsHighWater: Date?
    private var roomHighWater: [String: Date] = [:]
    private var threadHighWater: [String: Date] = [:]
    /// Open thread → its room, for routing room-level push signals.
    private var threadRooms: [String: String] = [:]

    private var pushTask: Task<Void, Never>?
    private var pushTransport: PushSignaling?
    /// While the push transport is healthy, polls stretch to a safety net —
    /// signals do the waking, ticks stay REST.
    private(set) var pushHealthy = false

    /// Thread windows live in the message store under a reserved key so they
    /// never collide with room ids.
    static func threadKey(_ threadId: String) -> String { "thread/\(threadId)" }

    private var state: SyncState = .idle
    private var consecutiveFailures = 0
    private var stateSubscribers: [UUID: AsyncStream<SyncState>.Continuation] = [:]

    init(
        rest: RESTClient,
        auth: AuthSession,
        clock: RESTClock,
        config: Config = Config(),
        roomStore: RoomStoring = InMemoryRoomStore(),
        messageStore: MessageStoring = InMemoryMessageStore(),
        markStore: SyncMarkStoring = InMemorySyncMarkStore()
    ) {
        self.rest = rest
        self.auth = auth
        self.clock = clock
        self.config = config
        self.roomStore = roomStore
        self.messageStore = messageStore
        self.markStore = markStore
    }

    // MARK: - Lifecycle

    func start() async {
        guard sidebarTask == nil else { return }
        setState(.syncing)
        await loadPersistedMarks()
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

    // MARK: - Push signals

    /// Attaches a push transport. Purely advisory: signals trigger the same
    /// REST ticks the poller runs; polling continues as a safety net.
    func attachPushSignals(_ transport: PushSignaling) {
        detachPushSignals()
        pushTransport = transport
        pushTask = Task { [weak self] in
            guard let transport = await self?.pushTransport else { return }
            for await signal in await transport.signals() {
                guard let self else { return }
                await self.handle(signal)
            }
            await self?.setPushHealthy(false)
        }
    }

    func detachPushSignals() {
        pushTask?.cancel()
        pushTask = nil
        let transport = pushTransport
        pushTransport = nil
        pushHealthy = false
        Task { await transport?.stop() }
    }

    private func handle(_ signal: PushSignal) async {
        switch signal {
        case .connected(let healthy):
            let cameUp = healthy && !pushHealthy
            pushHealthy = healthy
            if cameUp {
                // Catch up on anything missed while the bell was down.
                await tickSidebar()
                for roomId in roomTasks.keys {
                    await tickRoom(roomId)
                }
            }
        case .sidebarChanged:
            await tickSidebar()
        case .roomActivity(let roomId):
            // "Open" = has an initial-load high-water mark (poll task
            // existence would miss rooms opened without polling).
            if roomHighWater[roomId] != nil {
                await tickRoom(roomId)
            }
            for (threadId, threadRoom) in threadRooms where threadRoom == roomId {
                await tickThread(threadId)
            }
        }
    }

    private func setPushHealthy(_ healthy: Bool) {
        pushHealthy = healthy
    }

    func stop() {
        detachPushSignals()
        sidebarTask?.cancel()
        sidebarTask = nil
        for task in roomTasks.values {
            task.cancel()
        }
        roomTasks = [:]
        for task in threadTasks.values {
            task.cancel()
        }
        threadTasks = [:]
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

    /// With a persistent mark store, resume from the last session's server
    /// timestamps — the first tick is a delta, not a full re-sync.
    func loadPersistedMarks() async {
        if roomsHighWater == nil {
            roomsHighWater = await markStore.mark(for: "rooms")
        }
        if subscriptionsHighWater == nil {
            subscriptionsHighWater = await markStore.mark(for: "subscriptions")
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
            if let mark = roomsHighWater {
                await markStore.set(mark, for: "rooms")
            }
            if let mark = subscriptionsHighWater {
                await markStore.set(mark, for: "subscriptions")
            }

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
        // Upsert (not reset) so a persistent store keeps cached scroll-back;
        // the newest page corrects anything stale at the tail.
        await messageStore.apply(
            delta: MessageDelta(updated: page.messages, deleted: []), in: roomId)
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

    /// Pages older history until `messageId` is in the visible window, so
    /// the UI can jump to an arbitrary older message (e.g. a search result).
    /// Returns false when the message can't be surfaced: history ran out or
    /// `jumpWindowLimit` was reached first.
    func loadOlder(_ roomId: String, until messageId: String) async throws -> Bool {
        func isVisible() async -> Bool {
            await messageStore.snapshot(roomId).entries
                .contains { $0.id == messageId }
        }
        if await isVisible() { return true }
        let type = await roomStore.roomType(roomId) ?? .channel
        let maxPages = max(1, config.jumpWindowLimit / config.pageSize)
        for _ in 0..<maxPages {
            let offset = await messageStore.count(roomId)
            let page = try await rest.send(API.roomMessages(
                roomId: roomId, type: type, count: config.pageSize, offset: offset))
            if page.messages.isEmpty { return false }
            await messageStore.prepend(older: page.messages, in: roomId)
            if await isVisible() { return true }
        }
        return false
    }

    // MARK: - Thread tier

    /// Loads a thread's replies and starts its own fast poll loop. The window
    /// is stored under `threadKey`, separate from the room window.
    func openThread(_ threadId: String, roomId: String? = nil, startPolling: Bool = true) async throws {
        guard threadTasks[threadId] == nil else { return }
        if let roomId {
            threadRooms[threadId] = roomId
        }
        let page = try await rest.send(API.Chat.getThreadMessages(
            threadId: threadId, count: config.pageSize, offset: 0))
        await messageStore.resetRoom(Self.threadKey(threadId), messages: page.messages)
        var highWater: Date?
        advance(&highWater, past: page.messages.map { $0._updatedAt ?? $0.ts })
        threadHighWater[threadId] = highWater ?? clock.now

        guard startPolling else { return }
        threadTasks[threadId] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await self.roomInterval
                try? await self.clock.sleep(seconds: interval)
                if Task.isCancelled { return }
                await self.tickThread(threadId)
            }
        }
    }

    func closeThread(_ threadId: String) async {
        threadTasks[threadId]?.cancel()
        threadTasks[threadId] = nil
        threadHighWater[threadId] = nil
        threadRooms[threadId] = nil
        await messageStore.trim(Self.threadKey(threadId), to: 0)
    }

    func tickThread(_ threadId: String) async {
        guard let since = threadHighWater[threadId] else { return }
        do {
            let response = try await rest.send(API.Chat.syncThreadMessages(
                threadId: threadId, updatedSince: since))
            let delta = MessageDelta(
                updated: response.update,
                deleted: response.remove.map {
                    DeletedMessage(_id: $0._id, _deletedAt: $0._updatedAt)
                })
            var highWater: Date? = since
            advance(&highWater, past: delta.updated.map { $0._updatedAt ?? $0.ts })
            advance(&highWater, past: delta.deleted.compactMap(\._deletedAt))
            threadHighWater[threadId] = highWater
            if !delta.updated.isEmpty || !delta.deleted.isEmpty {
                await messageStore.apply(delta: delta, in: Self.threadKey(threadId))
            }
            noteTickSuccess()
        } catch {
            noteTickFailure(error)
        }
    }

    // MARK: - Sending (optimistic)

    func send(text: String, roomId: String, threadId: String? = nil) async throws {
        let messageId = MessageID.generate()
        let author = await auth.miniUser
        let optimistic = Message(
            _id: messageId, rid: roomId, msg: text,
            ts: clock.now, u: author, tmid: threadId)
        // Thread replies render in the thread window; top-level messages in
        // the room window.
        let windowKey = threadId.map(Self.threadKey) ?? roomId
        await messageStore.insertPending(optimistic, in: windowKey)
        do {
            let sent = try await rest.send(API.Chat.sendMessage(
                roomId: roomId, text: text, messageId: messageId, threadId: threadId))
            await messageStore.confirm(
                messageId: messageId, with: sent.message, in: windowKey)
            // A message of ours means an active conversation; catch up now
            // rather than waiting out the poll interval.
            if let threadId {
                await tickThread(threadId)
            } else {
                await tickRoom(roomId)
            }
        } catch {
            await messageStore.markFailed(messageId: messageId, in: windowKey)
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
        pushHealthy ? config.sidebarIdleInterval
            : appActive ? config.sidebarActiveInterval : config.sidebarIdleInterval
    }

    private var roomInterval: TimeInterval {
        pushHealthy ? config.roomIdleInterval
            : appActive ? config.roomActiveInterval : config.roomIdleInterval
    }

    private func advance(_ mark: inout Date?, past dates: [Date]) {
        guard let newest = dates.max() else { return }
        if mark.map({ newest > $0 }) ?? true {
            mark = newest
        }
    }
}
