import Foundation

/// The live-update mechanism and source of truth: tiered adaptive polling of
/// the REST delta endpoints. The realtime streamer accelerates it: its
/// payloads are applied immediately, and the next REST tick converges them.
///
/// - Sidebar tier: `subscriptions.get` + `rooms.get` with `updatedSince`
///   (2 requests/tick) keeps unread counts and previews fresh workspace-wide.
/// - Room tier: `chat.syncMessages` with `lastUpdate` (1 request/tick) delivers
///   inserts, edits, and deletions for each open room.
///
/// High-water marks come from server record timestamps (`_updatedAt`), never
/// the client clock, so ticks are also the recovery path after sleep or
/// network loss — no special reconnect logic exists or is needed. Stream
/// payloads never move a high-water mark, so a dropped event is always
/// re-covered by REST.
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
        /// Our typing broadcast repeats at most this often while typing…
        var typingResendInterval: TimeInterval = 3
        /// …and sends "stopped" after this long without input.
        var typingIdleTimeout: TimeInterval = 5
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
    /// Open thread → its room, for routing room-level realtime events.
    private var threadRooms: [String: String] = [:]

    private var realtimeTask: Task<Void, Never>?
    private var realtime: RealtimeTransport?
    /// While the realtime transport is healthy, polls stretch to a safety
    /// net — the stream does the live work, ticks keep converging.
    private(set) var realtimeHealthy = false
    /// Open rooms whose message stream is ready; they need no REST tick per
    /// activity bell.
    private(set) var liveRooms: Set<String> = []

    let typing: TypingTracker
    let presence = PresenceStore()
    private var trackedPresence: Set<String> = []

    /// Our own typing broadcast, per room/thread.
    private struct TypingSend {
        var lastSent: Date?
        var idleTask: Task<Void, Never>?
    }
    private var typingSends: [TypingTracker.Key: TypingSend] = [:]
    /// Server's `UI_Use_Real_Name`, read once: typing must be broadcast
    /// under the name the server checks against.
    private var useRealName: Bool?

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
        self.typing = TypingTracker(clock: clock)
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
                // Without the stream, presence degrades to polling too.
                if await !self.realtimeHealthy {
                    await self.refreshPresence()
                }
            }
        }
    }

    // MARK: - Realtime

    /// Attaches the realtime transport: watches every open room and tracked
    /// user, then applies its events. Polling continues as a safety net.
    func attachRealtime(_ transport: RealtimeTransport) async {
        detachRealtime()
        realtime = transport
        for roomId in roomHighWater.keys {
            await transport.watchRoom(roomId)
        }
        if !trackedPresence.isEmpty {
            await transport.watchPresence(added: Array(trackedPresence), removed: [])
        }
        realtimeTask = Task { [weak self] in
            for await event in await transport.events() {
                guard let self else { return }
                await self.handle(event)
            }
            await self?.realtimeStopped()
        }
    }

    func detachRealtime() {
        realtimeTask?.cancel()
        realtimeTask = nil
        let transport = realtime
        realtime = nil
        realtimeStopped()
        Task { await transport?.stop() }
    }

    private func realtimeStopped() {
        realtimeHealthy = false
        liveRooms = []
        for send in typingSends.values {
            send.idleTask?.cancel()
        }
        typingSends = [:]
        let typing = typing
        Task { await typing.clearAll() }
    }

    func handle(_ event: RealtimeEvent) async {
        switch event {
        case .connected(let healthy):
            let cameUp = healthy && !realtimeHealthy
            realtimeHealthy = healthy
            if !healthy {
                // No stops will arrive for this session's typists.
                liveRooms = []
                await typing.clearAll()
            }
            if cameUp {
                // Catch up on anything missed while the socket was down.
                await tickSidebar()
                for roomId in roomHighWater.keys {
                    await tickRoom(roomId)
                }
                for threadId in threadHighWater.keys {
                    await tickThread(threadId)
                }
                await refreshPresence()
            }

        case .message(let roomId, let message):
            if roomHighWater[roomId] != nil {
                await messageStore.apply(
                    delta: MessageDelta(updated: [message], deleted: []), in: roomId)
            }
            if let threadId = message.tmid, threadHighWater[threadId] != nil {
                await messageStore.apply(
                    delta: MessageDelta(updated: [message], deleted: []),
                    in: Self.threadKey(threadId))
            }

        case .messageDeleted(let roomId, let messageId):
            let delta = MessageDelta(updated: [], deleted: [DeletedMessage(_id: messageId)])
            if roomHighWater[roomId] != nil {
                await messageStore.apply(delta: delta, in: roomId)
            }
            for (threadId, threadRoom) in threadRooms where threadRoom == roomId {
                await messageStore.apply(delta: delta, in: Self.threadKey(threadId))
            }

        case .roomLive(let roomId, let live):
            if live, roomHighWater[roomId] != nil {
                liveRooms.insert(roomId)
            } else {
                liveRooms.remove(roomId)
            }

        case .typing(let roomId, let threadId, let name, let active):
            let me = await selfUser()
            guard name != me.username, name != me.name else { return }
            await typing.apply(roomId: roomId, threadId: threadId, name: name, active: active)

        case .presence(let update):
            await presence.apply([update])

        case .subscriptionChanged(let subscription):
            await roomStore.apply(
                roomsUpdated: [], roomsRemoved: [],
                subscriptionsUpdated: [subscription], subscriptionsRemoved: [])
        case .subscriptionRemoved(let roomId):
            await roomStore.apply(
                roomsUpdated: [], roomsRemoved: [],
                subscriptionsUpdated: [], subscriptionsRemoved: [roomId])
        case .roomChanged(let room):
            await roomStore.apply(
                roomsUpdated: [room], roomsRemoved: [],
                subscriptionsUpdated: [], subscriptionsRemoved: [])
        case .roomRemoved(let roomId):
            await roomStore.apply(
                roomsUpdated: [], roomsRemoved: [roomId],
                subscriptionsUpdated: [], subscriptionsRemoved: [])

        case .sidebarChanged:
            await tickSidebar()
        case .roomActivity(let roomId):
            // Live rooms already got the payload; the rest fall back to REST.
            // "Open" = has an initial-load high-water mark (poll task
            // existence would miss rooms opened without polling).
            guard !liveRooms.contains(roomId) else { return }
            if roomHighWater[roomId] != nil {
                await tickRoom(roomId)
            }
            for (threadId, threadRoom) in threadRooms where threadRoom == roomId {
                await tickThread(threadId)
            }
        }
    }

    // MARK: - Typing (outgoing)

    /// Call on composer input. Broadcasts "typing" at most every
    /// `typingResendInterval` and "stopped" after `typingIdleTimeout`
    /// without input. No-op without a realtime transport.
    func noteTyping(roomId: String, threadId: String?) async {
        guard let realtime else { return }
        let key = TypingTracker.Key(roomId: roomId, threadId: threadId)
        var send = typingSends[key] ?? TypingSend()
        let now = clock.now
        let due = send.lastSent.map {
            now.timeIntervalSince($0) >= config.typingResendInterval
        } ?? true
        if due {
            send.lastSent = now
        }
        send.idleTask?.cancel()
        send.idleTask = Task { [weak self, clock, config] in
            try? await clock.sleep(seconds: config.typingIdleTimeout)
            guard !Task.isCancelled else { return }
            await self?.stopTyping(roomId: roomId, threadId: threadId)
        }
        typingSends[key] = send
        if due {
            let name = await typingName()
            await realtime.sendTyping(
                roomId: roomId, threadId: threadId, name: name, active: true)
        }
    }

    /// Broadcasts "stopped" if we were typing (send, cleared draft, close).
    func stopTyping(roomId: String, threadId: String?) async {
        let key = TypingTracker.Key(roomId: roomId, threadId: threadId)
        guard let send = typingSends.removeValue(forKey: key) else { return }
        send.idleTask?.cancel()
        guard send.lastSent != nil, let realtime else { return }
        let name = await typingName()
        await realtime.sendTyping(
            roomId: roomId, threadId: threadId, name: name, active: false)
    }

    private func typingName() async -> String {
        if useRealName == nil,
           let response = try? await rest.send(
               API.Settings.publicValues(ids: ["UI_Use_Real_Name"])) {
            useRealName = response.settings
                .first { $0._id == "UI_Use_Real_Name" }?.value == .bool(true)
        }
        let me = await selfUser()
        return (useRealName == true ? me.name : nil) ?? me.username ?? me._id
    }

    /// Our username/name. A session adopted from a bare token (PAT) has no
    /// profile yet; load it once, since typing is broadcast — and our own
    /// echoes filtered — by name.
    private func selfUser() async -> MiniUser {
        let me = await auth.miniUser
        guard me.username == nil,
              let profile = try? await rest.send(API.Auth.me()) else { return me }
        await auth.setProfile(profile)
        return await auth.miniUser
    }

    // MARK: - Presence

    /// Starts tracking users' presence: REST seed for new ids, then live
    /// stream updates. Tracking is additive for the session.
    func trackPresence(_ userIds: [String]) async {
        let added = Set(userIds).subtracting(trackedPresence)
        guard !added.isEmpty else { return }
        trackedPresence.formUnion(added)
        await seedPresence(Array(added))
        await realtime?.watchPresence(added: Array(added), removed: [])
    }

    /// Re-reads every tracked user over REST — the presence recovery path.
    func refreshPresence() async {
        guard !trackedPresence.isEmpty else { return }
        await seedPresence(Array(trackedPresence))
    }

    private func seedPresence(_ userIds: [String]) async {
        let sorted = userIds.sorted()
        // Chunked to keep the `ids` query string a sane length.
        for start in stride(from: 0, to: sorted.count, by: 100) {
            let chunk = Array(sorted[start..<min(start + 100, sorted.count)])
            guard let response = try? await rest.send(API.Users.presence(ids: chunk))
            else { continue }
            await presence.apply(response.users.map {
                UserPresence(
                    userId: $0._id, username: $0.username,
                    status: $0.status ?? .unknown, statusText: $0.statusText)
            })
        }
    }

    func stop() {
        detachRealtime()
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
            await refreshPresence()
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
        await realtime?.watchRoom(roomId)
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
        liveRooms.remove(roomId)
        await realtime?.unwatchRoom(roomId)
        await stopTyping(roomId: roomId, threadId: nil)
        await typing.clear(roomId: roomId)
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
        if let roomId = threadRooms.removeValue(forKey: threadId) {
            await stopTyping(roomId: roomId, threadId: threadId)
        }
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
        await stopTyping(roomId: roomId, threadId: threadId)
        do {
            let sent = try await rest.send(API.Chat.sendMessage(
                roomId: roomId, text: text, messageId: messageId, threadId: threadId))
            await messageStore.confirm(
                messageId: messageId, with: sent.message, in: windowKey)
            // A message of ours means an active conversation; catch up now
            // rather than waiting out the poll interval (a live room gets
            // everything from the stream already).
            if !liveRooms.contains(roomId) {
                if let threadId {
                    await tickThread(threadId)
                } else {
                    await tickRoom(roomId)
                }
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
        realtimeHealthy ? config.sidebarIdleInterval
            : appActive ? config.sidebarActiveInterval : config.sidebarIdleInterval
    }

    private var roomInterval: TimeInterval {
        realtimeHealthy ? config.roomIdleInterval
            : appActive ? config.roomActiveInterval : config.roomIdleInterval
    }

    private func advance(_ mark: inout Date?, past dates: [Date]) {
        guard let newest = dates.max() else { return }
        if mark.map({ newest > $0 }) ?? true {
            mark = newest
        }
    }
}
