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

/// Opt-in push bell over the realtime streamer WebSocket.
///
/// Current scope: this transport doesn't decode message payloads, and no data
/// from it reaches the stores. It subscribes to the two user-level notify
/// streams and reduces every event to a `PushSignal` routing hint. The sync
/// engine then runs its normal REST delta ticks. Carrying payloads (messages,
/// typing, presence) is permitted by the project's API policy, as long as
/// REST sync stays the source of truth.
actor StreamerSignalTransport: PushSignaling {
    private let websocketURL: URL
    private let credentials: @Sendable () async -> AuthCredentials?
    private let socketFactory: SignalSocketFactory
    private let clock: RESTClock

    private var runner: Task<Void, Never>?
    private var socket: SignalSocket?
    private var stopped = false

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

    func signals() -> AsyncStream<PushSignal> {
        let (stream, continuation) = AsyncStream.makeStream(of: PushSignal.self)
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
        runner?.cancel()
        runner = nil
        let socket = socket
        self.socket = nil
        Task { await socket?.close() }
    }

    private var isStopped: Bool { stopped }

    private func sleep(_ seconds: TimeInterval) async throws {
        try await clock.sleep(seconds: seconds)
    }

    // MARK: - One socket session

    /// Returns true once the session was fully established (login + subs),
    /// so the caller can reset its reconnect backoff.
    private func runSession(
        _ continuation: AsyncStream<PushSignal>.Continuation
    ) async throws -> Bool {
        guard let credentials = await credentials() else {
            throw RocketChatError.notAuthenticated
        }
        let socket = socketFactory.makeSocket(url: websocketURL)
        self.socket = socket
        try await socket.connect()
        defer { Task { await socket.close() } }

        try await socket.send(#"{"msg":"connect","version":"1","support":["1"]}"#)

        // Handshake → resume login → subscribe both user notify streams.
        // Then reduce every incoming frame to a routing hint.
        var loggedIn = false
        var announced = false
        while !Task.isCancelled, !stopped {
            let frame = try await socket.receive()
            guard let message = Self.parse(frame) else { continue }

            switch message["msg"]?.stringValue {
            case "connected":
                let login = """
                    {"msg":"method","method":"login","id":"signal-login",
                     "params":[{"resume":"\(credentials.authToken)"}]}
                    """
                try await socket.send(login)
            case "ping":
                try await socket.send(#"{"msg":"pong"}"#)
            case "result":
                if message["id"]?.stringValue == "signal-login" {
                    if message["error"] != nil {
                        throw RocketChatError.notAuthenticated
                    }
                    loggedIn = true
                    for (index, event) in ["subscriptions-changed", "rooms-changed"]
                        .enumerated() {
                        let sub = """
                            {"msg":"sub","id":"signal-sub-\(index)",
                             "name":"stream-notify-user",
                             "params":["\(credentials.userId)/\(event)",false]}
                            """
                        try await socket.send(sub)
                    }
                }
            case "ready":
                if loggedIn, !announced {
                    announced = true
                    continuation.yield(.connected(true))
                }
            case "changed":
                for signal in Self.signals(from: message) {
                    continuation.yield(signal)
                }
            default:
                break   // server_id, updated, nosub, …
            }
        }
        return announced
    }

    // MARK: - Frame reduction (pure)

    static func parse(_ frame: String) -> JSONValue? {
        try? RCJSON.decoder().decode(JSONValue.self, from: Data(frame.utf8))
    }

    /// Reduces a `changed` event to routing hints. Only `eventName` and the
    /// changed room's `_id` are read — payload contents are ignored.
    static func signals(from message: JSONValue) -> [PushSignal] {
        guard message["collection"]?.stringValue == "stream-notify-user",
              let eventName = message["fields"]?["eventName"]?.stringValue
        else { return [] }

        if eventName.hasSuffix("/subscriptions-changed") {
            return [.sidebarChanged]
        }
        if eventName.hasSuffix("/rooms-changed") {
            // args: ["updated", { room record }]
            let args = message["fields"]?["args"]?.arrayValue ?? []
            if let roomId = args.last?["_id"]?.stringValue {
                return [.roomActivity(roomId: roomId), .sidebarChanged]
            }
            return [.sidebarChanged]
        }
        return []
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
