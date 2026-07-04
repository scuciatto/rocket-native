import Foundation

/// Entry point for a single Rocket.Chat server connection.
///
/// Instance-based by design: create one client per server/workspace.
/// The SDK is REST-only — live updates are delivered by an adaptive
/// delta-sync poller, not the deprecated realtime (DDP) API.
public final class RocketChatClient: Sendable {
    public let serverURL: URL
    let rest: RESTClient
    let auth: AuthSession
    let engine: SyncEngine

    public convenience init(
        serverURL: URL, transport: HTTPTransport = URLSessionTransport()
    ) {
        self.init(serverURL: serverURL, transport: transport, clock: SystemClock())
    }

    init(
        serverURL: URL, transport: HTTPTransport, clock: RESTClock,
        syncConfig: SyncEngine.Config = SyncEngine.Config()
    ) {
        self.serverURL = serverURL
        let auth = AuthSession()
        self.auth = auth
        let rest = RESTClient(
            serverURL: serverURL, transport: transport, auth: auth, clock: clock)
        self.rest = rest
        self.engine = SyncEngine(
            rest: rest, auth: auth, clock: clock, config: syncConfig)
    }

    // MARK: - Live sync

    /// Starts the sidebar poll loop. Requires credentials.
    public func startSync() async {
        await engine.start()
    }

    /// Stops all polling (sidebar and any open rooms).
    public func stopSync() async {
        await engine.stop()
    }

    /// Tell the SDK whether the app is frontmost; idle apps poll slower.
    public func setAppActive(_ active: Bool) async {
        await engine.setAppActive(active)
    }

    /// Sidebar snapshots: yields current state immediately, then on change.
    public func roomListUpdates() async -> AsyncStream<[RoomSummary]> {
        await engine.roomStore.updates()
    }

    /// Poll-loop health, for a connection indicator.
    public func syncStateUpdates() async -> AsyncStream<SyncState> {
        await engine.stateUpdates()
    }

    /// Opens a live view into a room: loads the newest page and starts the
    /// fast poll loop. Call `close()` on the handle when done.
    public func openRoom(_ roomId: String) async throws -> RoomHandle {
        try await engine.openRoom(roomId)
        return RoomHandle(roomId: roomId, engine: engine, client: self)
    }

    // MARK: - Authentication

    /// Logs in with username/email + password.
    ///
    /// If the account has 2FA enabled this throws
    /// `RocketChatError.twoFactorRequired(challenge)`; prompt for a code and
    /// call `completeTwoFactorLogin(_:code:method:)` with that challenge.
    @discardableResult
    public func login(user: String, password: String) async throws -> UserProfile {
        let response = try await rest.send(API.Auth.login(user: user, password: password))
        return await adoptSession(from: response)
    }

    /// Completes a 2FA-challenged login by replaying it with the user's code.
    /// Throws `RocketChatError.twoFactorInvalid` (carrying a fresh challenge,
    /// so the user can retry) when the code is wrong.
    @discardableResult
    public func completeTwoFactorLogin(
        _ challenge: TwoFactorChallenge,
        code: String,
        method: TwoFactorMethod
    ) async throws -> UserProfile {
        let response = try await rest.replay(
            challenge, code: code, method: method, expecting: LoginResponse.self)
        return await adoptSession(from: response)
    }

    /// Asks the server to (re)send an email 2FA code.
    public func sendEmailCode(emailOrUsername: String) async throws {
        _ = try await rest.send(API.Auth.sendEmailCode(emailOrUsername: emailOrUsername))
    }

    /// Resumes a previous session from stored credentials, refreshing the token.
    @discardableResult
    public func resume(credentials: AuthCredentials) async throws -> UserProfile {
        let response = try await rest.send(API.Auth.resume(token: credentials.authToken))
        return await adoptSession(from: response)
    }

    /// Adopts a personal access token (or any token pair) without a login round trip.
    public func adopt(credentials: AuthCredentials) async {
        await auth.set(credentials)
    }

    /// Current token pair, for the caller to persist (e.g. in the Keychain).
    public var credentials: AuthCredentials? {
        get async { await auth.credentials }
    }

    public func me() async throws -> UserProfile {
        let profile = try await rest.send(API.Auth.me())
        await auth.setProfile(profile)
        return profile
    }

    public func logout() async throws {
        _ = try? await rest.send(API.Auth.logout())
        await auth.set(nil)
    }

    // MARK: - Rooms

    /// Fetches all joined rooms with their per-user state, joined into
    /// sidebar-ready summaries, sorted by most recent activity.
    public func rooms() async throws -> [RoomSummary] {
        async let roomsDelta = rest.send(API.Rooms.get())
        async let subscriptionsDelta = rest.send(API.Subscriptions.get())
        let roomsById = Dictionary(
            uniqueKeysWithValues: try await roomsDelta.update.map { ($0._id, $0) })
        return try await subscriptionsDelta.update
            .map { RoomSummary(room: roomsById[$0.rid], subscription: $0) }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    public func markRead(roomId: String) async throws {
        _ = try await rest.send(API.Subscriptions.read(roomId: roomId))
    }

    // MARK: - Messages

    /// Latest messages in a room, newest first, offset-paged.
    public func history(
        roomId: String, type: RoomType, count: Int = 50, offset: Int = 0
    ) async throws -> [Message] {
        try await rest.send(
            API.roomMessages(roomId: roomId, type: type, count: count, offset: offset)
        ).messages
    }

    /// Everything that changed in a room since `lastUpdate` — new messages,
    /// edits, and deletions.
    public func syncMessages(roomId: String, since: Date) async throws -> MessageDelta {
        let response = try await rest.send(
            API.Chat.syncMessages(roomId: roomId, lastUpdate: since))
        return MessageDelta(
            updated: response.result.updated,
            deleted: response.result.deleted ?? [])
    }

    /// Sends a message. The id is client-generated (pass `messageId` to supply
    /// your own, e.g. for optimistic UI); the server honors it, so a later
    /// delta upserts rather than duplicates.
    @discardableResult
    public func send(
        text: String, roomId: String,
        threadId: String? = nil, messageId: String? = nil
    ) async throws -> Message {
        try await rest.send(API.Chat.sendMessage(
            roomId: roomId, text: text,
            messageId: messageId ?? MessageID.generate(), threadId: threadId)
        ).message
    }

    @discardableResult
    public func edit(messageId: String, roomId: String, text: String) async throws -> Message {
        try await rest.send(API.Chat.update(
            roomId: roomId, messageId: messageId, text: text)
        ).message
    }

    public func delete(messageId: String, roomId: String) async throws {
        _ = try await rest.send(API.Chat.delete(roomId: roomId, messageId: messageId))
    }

    public func react(messageId: String, emoji: String, on: Bool? = nil) async throws {
        _ = try await rest.send(API.Chat.react(
            messageId: messageId, emoji: emoji, shouldReact: on))
    }

    // MARK: - Threads

    /// Thread parents in a room (messages carrying `tcount`/`tlm`), newest first.
    public func threads(
        in roomId: String, filter: ThreadFilter = .all, text: String? = nil,
        count: Int = 50, offset: Int = 0
    ) async throws -> [Message] {
        try await rest.send(API.Chat.getThreadsList(
            roomId: roomId, filter: filter, text: text, count: count, offset: offset)
        ).threads
    }

    /// Opens a live view into a thread: loads its replies and starts a fast
    /// poll loop. Call `close()` on the handle when done.
    public func openThread(_ threadId: String, in roomId: String) async throws -> ThreadHandle {
        try await engine.openThread(threadId)
        return ThreadHandle(threadId: threadId, roomId: roomId, engine: engine, client: self)
    }

    /// Follow/unfollow a thread (its parent message id).
    public func followThread(_ messageId: String, follow: Bool = true) async throws {
        _ = try await rest.send(
            follow
                ? API.Chat.followMessage(messageId: messageId)
                : API.Chat.unfollowMessage(messageId: messageId))
    }

    // MARK: - Search & directory

    /// Full-text message search within one room.
    public func searchMessages(
        in roomId: String, text: String, count: Int = 20, offset: Int = 0
    ) async throws -> [Message] {
        try await rest.send(API.Search.chatSearch(
            roomId: roomId, text: text, count: count, offset: offset)
        ).messages
    }

    /// Global search for users and reachable-but-not-joined rooms.
    /// Supports `#channel` and `@user` prefixes.
    public func spotlight(_ query: String) async throws -> SpotlightResult {
        try await rest.send(API.Search.spotlight(query: query))
    }

    /// Workspace directory listing (users, channels, or teams).
    public func directory(
        text: String, type: DirectoryType = .channels, count: Int = 20, offset: Int = 0
    ) async throws -> Paginated<DirectoryEntry> {
        let response = try await rest.send(API.Search.directory(
            text: text, type: type, count: count, offset: offset))
        return Paginated(
            items: response.result,
            offset: response.offset ?? offset,
            total: response.total ?? response.result.count)
    }

    /// Joins a public channel (e.g. one found via spotlight/directory) and
    /// triggers a sidebar catch-up so it appears in the room list promptly.
    @discardableResult
    public func joinChannel(roomId: String) async throws -> Room {
        let room = try await rest.send(API.RoomActions.joinChannel(roomId: roomId)).channel
        await engine.tickSidebar()
        return room
    }

    /// Opens (or creates) a direct-message room with a user.
    @discardableResult
    public func createDirectMessage(username: String) async throws -> Room {
        let room = try await rest.send(API.RoomActions.createDM(username: username)).room
        await engine.tickSidebar()
        return room
    }

    public func userInfo(username: String) async throws -> UserProfile {
        try await rest.send(API.Users.info(username: username)).user
    }

    /// Avatar URL for a username. Append the user's `avatarETag` when known so
    /// avatar changes bust image caches naturally.
    public func avatarURL(username: String, size: Int? = nil, etag: String? = nil) -> URL {
        var components = URLComponents(
            url: serverURL.appending(path: "avatar/\(username)"),
            resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "format", value: "png")]
        if let size {
            query.append(URLQueryItem(name: "size", value: String(size)))
        }
        if let etag {
            query.append(URLQueryItem(name: "etag", value: etag))
        }
        components.queryItems = query
        return components.url!
    }

    private func adoptSession(from response: LoginResponse) async -> UserProfile {
        let credentials = AuthCredentials(
            authToken: response.data.authToken,
            userId: response.data.userId)
        await auth.set(credentials)
        if let me = response.data.me {
            await auth.setProfile(me)
            return me
        }
        return (try? await me()) ?? UserProfile(_id: response.data.userId)
    }
}
