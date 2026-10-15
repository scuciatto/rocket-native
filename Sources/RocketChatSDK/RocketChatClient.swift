import Foundation

/// Entry point for a single Rocket.Chat server connection.
///
/// Instance-based by design: create one client per server/workspace.
/// Requests go through REST only (DDP methods are deprecated). Live updates
/// come from an adaptive delta-sync poller, optionally accelerated by the
/// realtime streamer (`enablePushSignals()`).
/// Where the SDK keeps rooms, messages, and sync marks.
public enum CacheStorage: Sendable {
    /// No persistence; everything re-syncs on launch (v1 default).
    case inMemory
    /// SQLite files in `directory` (one set per server host): offline
    /// history, instant cold launch, and delta re-sync across launches.
    case sqlite(directory: URL)
}

public final class RocketChatClient: Sendable {
    public let serverURL: URL
    /// The SQLite cache file backing this client, when one is in use.
    /// Siblings `<file>-wal` / `<file>-shm` belong to it too.
    public let cacheFileURL: URL?
    let rest: RESTClient
    let auth: AuthSession
    let engine: SyncEngine

    public convenience init(
        serverURL: URL, transport: HTTPTransport = URLSessionTransport()
    ) {
        self.init(serverURL: serverURL, transport: transport, clock: SystemClock())
    }

    /// Creates a client with the given cache backing. Throws only for
    /// `.sqlite` when the database cannot be created/opened.
    public convenience init(
        serverURL: URL, cache: CacheStorage,
        transport: HTTPTransport = URLSessionTransport()
    ) throws {
        switch cache {
        case .inMemory:
            self.init(serverURL: serverURL, transport: transport, clock: SystemClock())
        case .sqlite(let directory):
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let file = Self.cacheFileURL(directory: directory, serverURL: serverURL)
            // percentEncoded: false — SQLite gets a filesystem path, and
            // "Application Support" must not become "Application%20Support".
            let path = file.path(percentEncoded: false)
            self.init(
                serverURL: serverURL, transport: transport, clock: SystemClock(),
                cacheFileURL: file,
                roomStore: try SQLiteRoomStore(path: path),
                messageStore: try SQLiteMessageStore(path: path),
                markStore: try SQLiteSyncMarkStore(path: path))
        }
    }

    /// Conventional cache file location for a server, so callers can remove
    /// the cache (plus `-wal`/`-shm` siblings) on logout.
    public static func cacheFileURL(directory: URL, serverURL: URL) -> URL {
        let host = serverURL.host() ?? "server"
        return directory.appending(path: "\(host).sqlite")
    }

    init(
        serverURL: URL, transport: HTTPTransport, clock: RESTClock,
        syncConfig: SyncEngine.Config = SyncEngine.Config(),
        cacheFileURL: URL? = nil,
        roomStore: RoomStoring = InMemoryRoomStore(),
        messageStore: MessageStoring = InMemoryMessageStore(),
        markStore: SyncMarkStoring = InMemorySyncMarkStore()
    ) {
        self.serverURL = serverURL
        self.cacheFileURL = cacheFileURL
        let auth = AuthSession()
        self.auth = auth
        let rest = RESTClient(
            serverURL: serverURL, transport: transport, auth: auth, clock: clock)
        self.rest = rest
        self.engine = SyncEngine(
            rest: rest, auth: auth, clock: clock, config: syncConfig,
            roomStore: roomStore, messageStore: messageStore, markStore: markStore)
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

    /// Opt-in push bell: uses the realtime streamer WebSocket as a
    /// "something changed" signal — every payload still flows through REST
    /// delta sync, and polling continues as a safety net. If the socket
    /// can't connect, behavior degrades silently to plain polling.
    public func enablePushSignals() async {
        let auth = self.auth
        let transport = StreamerSignalTransport(
            serverURL: serverURL,
            credentials: { await auth.credentials })
        await engine.attachPushSignals(transport)
    }

    public func disablePushSignals() async {
        await engine.detachPushSignals()
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
    /// `method` defaults to `challenge.method` (the server verifies login
    /// codes with its first active method regardless). Throws
    /// `RocketChatError.twoFactorInvalid` (carrying a retry challenge with the
    /// same `id`) when the code is wrong.
    @discardableResult
    public func completeTwoFactorLogin(
        _ challenge: TwoFactorChallenge,
        code: String,
        method: TwoFactorMethod? = nil
    ) async throws -> UserProfile {
        let response = try await rest.replay(
            challenge, code: code, method: method, expecting: LoginResponse.self)
        return await adoptSession(from: response)
    }

    /// Installs the prompt used when an authenticated call hits 2FA
    /// mid-session; the call then replays transparently once a code is
    /// accepted, or throws `.cancelled` if the user dismisses the prompt.
    /// Without a provider such calls throw `.twoFactorRequired`.
    public func setTwoFactorProvider(_ provider: TwoFactorCodeProvider?) async {
        await rest.setTwoFactorProvider(provider)
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

    /// Marks a room unread again (its badge reappears), with an immediate
    /// sidebar catch-up so the change is visible right away.
    public func markUnread(roomId: String) async throws {
        _ = try await rest.send(API.Subscriptions.unread(roomId: roomId))
        await engine.tickSidebar()
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

    /// Fetches one message by id (e.g. a thread reply's parent).
    public func getMessage(_ messageId: String) async throws -> Message {
        try await rest.send(API.Chat.getMessage(messageId: messageId)).message
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

    /// Uploads a file into a room (optionally as a thread reply) and posts it,
    /// with optional accompanying text and description. Two REST steps:
    /// `rooms.media` (bytes) then `rooms.mediaConfirm` (the message).
    @discardableResult
    public func uploadFile(
        _ file: UploadableFile, roomId: String,
        text: String? = nil, description: String? = nil, threadId: String? = nil
    ) async throws -> Message? {
        let uploaded = try await rest.send(API.Rooms.media(roomId: roomId, file: file))
        let confirmed = try await rest.send(API.Rooms.mediaConfirm(
            roomId: roomId, fileId: uploaded.file._id,
            text: text, description: description, threadId: threadId))
        return confirmed.message
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
        try await engine.openThread(threadId, roomId: roomId)
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

    /// Workspace-wide user autocomplete for `@mention` suggestions, filtered
    /// server-side by `term`.
    public func autocompleteUsers(term: String) async throws -> [MentionUser] {
        try await rest.send(API.Users.autocomplete(term: term)).items
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

    // MARK: - Personal access tokens

    /// Creates a personal access token and returns its secret (shown once).
    /// 2FA-protected: answered by the installed `TwoFactorCodeProvider`.
    public func generatePersonalAccessToken(
        name: String, bypassTwoFactor: Bool = false
    ) async throws -> String {
        try await rest.send(API.Users.generatePersonalAccessToken(
            name: name, bypassTwoFactor: bypassTwoFactor)).token
    }

    /// Revokes a personal access token by name. 2FA-protected.
    public func removePersonalAccessToken(name: String) async throws {
        _ = try await rest.send(API.Users.removePersonalAccessToken(name: name))
    }

    // MARK: - Custom emoji

    /// Custom emoji changed since `updatedSince` (all of them when nil), plus
    /// ids deleted since then. Feed into `CustomEmojiIndex.apply`.
    public func customEmojis(updatedSince: Date? = nil) async throws -> CustomEmojiDelta {
        let response = try await rest.send(API.EmojiCustom.list(updatedSince: updatedSince))
        return CustomEmojiDelta(
            update: response.emojis.update,
            remove: response.emojis.remove?.map(\._id) ?? [])
    }

    /// Image URL for a custom emoji. The route is unauthenticated; the etag
    /// busts caches when an emoji is re-uploaded under the same name.
    public func customEmojiURL(_ emoji: CustomEmoji) -> URL {
        var components = URLComponents(
            url: serverURL.appending(path: "emoji-custom/\(emoji.name).\(emoji.extension)"),
            resolvingAgainstBaseURL: false)!
        if let etag = emoji.etag {
            components.queryItems = [URLQueryItem(name: "etag", value: etag)]
        }
        return components.url!
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
