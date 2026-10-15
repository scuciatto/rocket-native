import Foundation

/// WebSocket seam so the transport is testable with scripted frames.
protocol SignalSocket: Sendable {
    func connect() async throws
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close() async
}

protocol SignalSocketFactory: Sendable {
    func makeSocket(url: URL) -> SignalSocket
}

/// Realtime over the server's DDP streamer WebSocket (`/websocket`).
///
/// Subscriptions only — no DDP methods except the two the streamer itself
/// needs: `login` with the resume token (socket auth) and the
/// `stream-notify-room` write that broadcasts our typing state. Every request
/// and action stays on REST.
///
/// Streams:
/// - always: `stream-notify-user` `<uid>/subscriptions-changed` and
///   `<uid>/rooms-changed` (sidebar records);
/// - per watched room: `stream-room-messages` `<rid>` plus
///   `stream-notify-room` `<rid>/deleteMessage` and `<rid>/user-activity`;
/// - per watched user: `stream-user-presence`.
///
/// The desired subscription set lives here and is replayed after every
/// reconnect, so callers watch/unwatch without caring about socket state.
actor StreamerTransport: RealtimeTransport {
    private let websocketURL: URL
    private let credentials: @Sendable () async -> AuthCredentials?
    private let socketFactory: SignalSocketFactory
    private let clock: RESTClock

    private var runner: Task<Void, Never>?
    private var socket: SignalSocket?
    private var stopped = false

    /// Desired state, replayed on every (re)login.
    private var watchedRooms: Set<String> = []
    private var presenceUserIds: Set<String> = []

    /// True between a successful socket login and the session's end; only
    /// then are subscription changes sent immediately.
    private var sessionReady = false
    private var frameCounter = 0

    init(
        serverURL: URL,
        credentials: @escaping @Sendable () async -> AuthCredentials?,
        socketFactory: SignalSocketFactory = URLSessionSignalSocketFactory(),
        clock: RESTClock = SystemClock()
    ) {
        var components = URLComponents(
            url: serverURL.appending(path: "websocket"),
            resolvingAgainstBaseURL: false)!
        components.scheme = serverURL.scheme == "http" ? "ws" : "wss"
        self.websocketURL = components.url!
        self.credentials = credentials
        self.socketFactory = socketFactory
        self.clock = clock
    }

    func events() -> AsyncStream<RealtimeEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: RealtimeEvent.self)
        stopped = false
        runner = Task { [weak self] in
            var backoff: TimeInterval = 1
            while let self, await !self.isStopped, !Task.isCancelled {
                let established = (try? await self.runSession(continuation)) ?? false
                if established {
                    backoff = 1
                }
                continuation.yield(.connected(false))
                guard await !self.isStopped, !Task.isCancelled else { break }
                try? await self.sleep(backoff)
                backoff = min(backoff * 2, 30)
            }
            continuation.finish()
        }
        return stream
    }

    func stop() {
        stopped = true
        sessionReady = false
        runner?.cancel()
        runner = nil
        let socket = socket
        self.socket = nil
        Task { await socket?.close() }
    }

    // MARK: - Desired subscriptions

    func watchRoom(_ roomId: String) async {
        guard watchedRooms.insert(roomId).inserted else { return }
        guard sessionReady, let socket else { return }
        try? await subscribeRoom(roomId, on: socket)
    }

    func unwatchRoom(_ roomId: String) async {
        guard watchedRooms.remove(roomId) != nil else { return }
        guard sessionReady, let socket else { return }
        for id in Self.roomSubIds(roomId) {
            try? await socket.send(Self.frame(["msg": "unsub", "id": .string(id)]))
        }
    }

    func watchPresence(added: [String], removed: [String]) async {
        let added = added.filter { !presenceUserIds.contains($0) }
        let removed = removed.filter { presenceUserIds.contains($0) }
        presenceUserIds.formUnion(added)
        presenceUserIds.subtract(removed)
        guard !added.isEmpty || !removed.isEmpty, sessionReady, let socket else { return }
        try? await subscribePresence(added: added, removed: removed, on: socket)
    }

    func sendTyping(roomId: String, threadId: String?, name: String, active: Bool) async {
        guard sessionReady, let socket else { return }
        var extra: [String: JSONValue] = [:]
        if let threadId {
            extra["tmid"] = .string(threadId)
        }
        let frame = Self.frame([
            "msg": "method",
            "method": "stream-notify-room",
            "id": .string(nextFrameId("typing")),
            "params": .array([
                .string("\(roomId)/user-activity"),
                .string(name),
                .array(active ? [.string("user-typing")] : []),
                .object(extra),
            ]),
        ])
        try? await socket.send(frame)
    }

    private var isStopped: Bool { stopped }

    private func sleep(_ seconds: TimeInterval) async throws {
        try await clock.sleep(seconds: seconds)
    }

    private func nextFrameId(_ prefix: String) -> String {
        frameCounter += 1
        return "\(prefix)-\(frameCounter)"
    }

    // MARK: - One socket session

    static let loginId = "realtime-login"
    static let userSubIds = ["user-subscriptions", "user-rooms"]

    static func roomSubIds(_ roomId: String) -> [String] {
        ["room-msg-\(roomId)", "room-del-\(roomId)", "room-act-\(roomId)"]
    }

    /// Returns true once the session was fully established (login + user
    /// subs ready), so the caller can reset its reconnect backoff.
    private func runSession(
        _ continuation: AsyncStream<RealtimeEvent>.Continuation
    ) async throws -> Bool {
        guard let credentials = await credentials() else {
            throw RocketChatError.notAuthenticated
        }
        let socket = socketFactory.makeSocket(url: websocketURL)
        self.socket = socket
        try await socket.connect()
        defer {
            sessionReady = false
            Task { await socket.close() }
        }

        try await socket.send(Self.frame([
            "msg": "connect", "version": "1", "support": .array(["1"]),
        ]))

        // Handshake → resume login → user subs + replay desired subs.
        // Then route every incoming frame.
        var pendingUserSubs = Set(Self.userSubIds)
        var announced = false
        while !Task.isCancelled, !stopped {
            let frame = try await socket.receive()
            guard let message = Self.parse(frame) else { continue }

            switch message["msg"]?.stringValue {
            case "connected":
                try await socket.send(Self.frame([
                    "msg": "method", "method": "login", "id": .string(Self.loginId),
                    "params": .array([.object(["resume": .string(credentials.authToken)])]),
                ]))
            case "ping":
                try await socket.send(Self.frame(["msg": "pong"]))
            case "result":
                guard message["id"]?.stringValue == Self.loginId else { break }
                if message["error"] != nil {
                    throw RocketChatError.notAuthenticated
                }
                sessionReady = true
                for (id, event) in zip(Self.userSubIds, ["subscriptions-changed", "rooms-changed"]) {
                    try await socket.send(Self.subFrame(
                        id: id, name: "stream-notify-user",
                        param: "\(credentials.userId)/\(event)"))
                }
                for roomId in watchedRooms {
                    try await subscribeRoom(roomId, on: socket)
                }
                if !presenceUserIds.isEmpty {
                    try await subscribePresence(
                        added: Array(presenceUserIds), removed: [], on: socket)
                }
            case "ready":
                let subs = message["subs"]?.arrayValue?.compactMap(\.stringValue) ?? []
                pendingUserSubs.subtract(subs)
                if sessionReady, pendingUserSubs.isEmpty, !announced {
                    announced = true
                    continuation.yield(.connected(true))
                }
                for sub in subs where sub.hasPrefix("room-msg-") {
                    let roomId = String(sub.dropFirst("room-msg-".count))
                    if watchedRooms.contains(roomId) {
                        continuation.yield(.roomLive(roomId: roomId, true))
                    }
                }
            case "nosub":
                // Permission denied or server-side stop: fall back to ticks.
                if let sub = message["id"]?.stringValue, sub.hasPrefix("room-msg-") {
                    let roomId = String(sub.dropFirst("room-msg-".count))
                    continuation.yield(.roomLive(roomId: roomId, false))
                }
            case "changed":
                for event in Self.events(from: message) {
                    continuation.yield(event)
                }
            default:
                break   // server_id, updated, added, …
            }
        }
        return announced
    }

    private func subscribeRoom(_ roomId: String, on socket: SignalSocket) async throws {
        let ids = Self.roomSubIds(roomId)
        try await socket.send(Self.subFrame(
            id: ids[0], name: "stream-room-messages", param: roomId))
        try await socket.send(Self.subFrame(
            id: ids[1], name: "stream-notify-room", param: "\(roomId)/deleteMessage"))
        try await socket.send(Self.subFrame(
            id: ids[2], name: "stream-notify-room", param: "\(roomId)/user-activity"))
    }

    /// Presence subs are batched per connection: the first one stays live,
    /// later ones only add/remove ids (the server stops them right away).
    private func subscribePresence(
        added: [String], removed: [String], on socket: SignalSocket
    ) async throws {
        try await socket.send(Self.frame([
            "msg": "sub", "id": .string(nextFrameId("presence")),
            "name": "stream-user-presence",
            "params": .array([
                .string(""),
                .object([
                    "added": .array(added.sorted().map(JSONValue.string)),
                    "removed": .array(removed.sorted().map(JSONValue.string)),
                ]),
            ]),
        ]))
    }

    // MARK: - Frames

    static func parse(_ frame: String) -> JSONValue? {
        try? RCJSON.decoder().decode(JSONValue.self, from: Data(frame.utf8))
    }

    static func frame(_ fields: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(JSONValue.object(fields))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func subFrame(id: String, name: String, param: String) -> String {
        frame([
            "msg": "sub", "id": .string(id), "name": .string(name),
            "params": .array([.string(param), .bool(false)]),
        ])
    }

    /// Decodes a stream payload into an SDK model, through the same lenient
    /// decoder REST responses use (handles `{"$date": ms}` dates).
    static func decode<T: Decodable>(_ value: JSONValue?) -> T? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? RCJSON.decoder().decode(T.self, from: data)
    }

    // MARK: - Event reduction (pure)

    /// Maps a `changed` frame to events. Payloads that don't decode degrade
    /// to the matching bell event, so REST still picks the change up.
    static func events(from message: JSONValue) -> [RealtimeEvent] {
        let fields = message["fields"]
        let eventName = fields?["eventName"]?.stringValue ?? ""
        let args = fields?["args"]?.arrayValue ?? []

        switch message["collection"]?.stringValue {
        case "stream-room-messages":
            guard !eventName.isEmpty, let payload = args.first else { return [] }
            if let decoded: Message = decode(payload) {
                return [.message(roomId: eventName, decoded)]
            }
            return [.roomActivity(roomId: eventName)]

        case "stream-notify-room":
            guard let slash = eventName.firstIndex(of: "/") else { return [] }
            let roomId = String(eventName[..<slash])
            switch eventName[eventName.index(after: slash)...] {
            case "deleteMessage":
                if let messageId = args.first?["_id"]?.stringValue {
                    return [.messageDeleted(roomId: roomId, messageId: messageId)]
                }
                return [.roomActivity(roomId: roomId)]
            case "user-activity":
                guard let username = args.first?.stringValue,
                      args.count > 1, let activities = args[1].arrayValue
                else { return [] }
                let threadId = args.count > 2 ? args[2]["tmid"]?.stringValue : nil
                return [.typing(
                    roomId: roomId, threadId: threadId, username: username,
                    active: activities.contains(.string("user-typing")))]
            default:
                return []
            }

        case "stream-notify-user":
            // args: [action ("inserted" | "updated" | "removed"), record]
            let action = args.first?.stringValue
            let record = args.count > 1 ? args[1] : nil
            if eventName.hasSuffix("/subscriptions-changed") {
                if action == "removed" {
                    return record?["rid"]?.stringValue
                        .map { [.subscriptionRemoved(roomId: $0)] } ?? [.sidebarChanged]
                }
                if let subscription: Subscription = decode(record) {
                    return [.subscriptionChanged(subscription)]
                }
                return [.sidebarChanged]
            }
            if eventName.hasSuffix("/rooms-changed") {
                let roomId = record?["_id"]?.stringValue
                if action == "removed" {
                    return roomId.map { [.roomRemoved(roomId: $0)] } ?? [.sidebarChanged]
                }
                // rooms-changed fires on every new message (lastMessage), so
                // it doubles as the activity bell for rooms not yet live.
                if let room: Room = decode(record) {
                    return [.roomChanged(room), .roomActivity(roomId: room._id)]
                }
                return roomId.map { [.roomActivity(roomId: $0), .sidebarChanged] }
                    ?? [.sidebarChanged]
            }
            return []

        case "stream-user-presence":
            // fields: {uid, args: [[username, code, statusText?, …]]}
            let userId = fields?["uid"]?.stringValue ?? eventName
            guard !userId.isEmpty, let entry = args.first?.arrayValue, entry.count > 1,
                  let code = entry[1].numberValue
            else { return [] }
            return [.presence(UserPresence(
                userId: userId,
                username: entry[0].stringValue,
                status: PresenceStatus(code: Int(code)),
                statusText: entry.count > 2 ? entry[2].stringValue : nil))]

        default:
            return []
        }
    }
}

// MARK: - Production socket

struct URLSessionSignalSocketFactory: SignalSocketFactory {
    func makeSocket(url: URL) -> SignalSocket {
        URLSessionSignalSocket(url: url)
    }
}

final class URLSessionSignalSocket: SignalSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        task = URLSession(configuration: configuration).webSocketTask(with: url)
    }

    func connect() async throws {
        task.resume()
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text):
            return text
        case .data(let data):
            return String(data: data, encoding: .utf8) ?? ""
        @unknown default:
            return ""
        }
    }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
