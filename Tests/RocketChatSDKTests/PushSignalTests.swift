import Testing
import Foundation
@testable import RocketChatSDK

private let serverURL = URL(string: "https://chat.example.com")!
private let emptyPage = #"{"messages": [], "count": 0, "offset": 0, "total": 0, "success": true}"#
private let emptyDelta = #"{"update": [], "remove": [], "success": true}"#
private let emptySync = #"{"result": {"updated": [], "deleted": []}, "success": true}"#

// MARK: - Scripted socket

/// Feeds scripted frames to the transport and records what it sends.
final class MockSignalSocket: SignalSocket, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sent: [String] = []
    private var incomingContinuation: AsyncStream<String>.Continuation?
    private var incomingIterator: AsyncStream<String>.AsyncIterator

    init(script: [String]) {
        var continuation: AsyncStream<String>.Continuation?
        let stream = AsyncStream<String> { continuation = $0 }
        self.incomingIterator = stream.makeAsyncIterator()
        self.incomingContinuation = continuation
        for frame in script {
            continuation?.yield(frame)
        }
    }

    /// Push an extra frame after construction (e.g. live events).
    func feed(_ frame: String) {
        incomingContinuation?.yield(frame)
    }

    func finishIncoming() {
        incomingContinuation?.finish()
    }

    func connect() async throws {}

    func send(_ text: String) async throws {
        lock.withLock { sent.append(text) }

        // Emulate the server's handshake responses.
        if text.contains(#""msg":"connect""#) {
            feed(#"{"msg":"connected","session":"s1"}"#)
        } else if text.contains("signal-login") {
            feed(#"{"msg":"result","id":"signal-login","result":{"id":"uid-9"}}"#)
        } else if text.contains("signal-sub-1") {
            feed(#"{"msg":"ready","subs":["signal-sub-0","signal-sub-1"]}"#)
        }
    }

    func receive() async throws -> String {
        if let frame = await incomingIterator.next() {
            return frame
        }
        throw URLError(.networkConnectionLost)
    }

    func close() async {}

    var sentFrames: [String] {
        lock.withLock { sent }
    }
}

private final class MockSocketFactory: SignalSocketFactory, @unchecked Sendable {
    let socket: MockSignalSocket

    init(socket: MockSignalSocket) {
        self.socket = socket
    }

    func makeSocket(url: URL) -> SignalSocket {
        socket
    }
}

// MARK: - Frame reduction

@Suite struct SignalFrameReductionTests {
    private func changed(eventName: String, args: String = "[]") -> JSONValue {
        StreamerSignalTransport.parse("""
            {"msg":"changed","collection":"stream-notify-user","id":"id",
             "fields":{"eventName":"\(eventName)","args":\(args)}}
            """)!
    }

    @Test func subscriptionsChangedBecomesSidebarSignal() {
        let signals = StreamerSignalTransport.signals(
            from: changed(eventName: "uid-9/subscriptions-changed"))
        #expect(signals == [.sidebarChanged])
    }

    @Test func roomsChangedCarriesRoomId() {
        let signals = StreamerSignalTransport.signals(
            from: changed(
                eventName: "uid-9/rooms-changed",
                args: #"["updated", {"_id": "r42", "msgs": 10}]"#))
        #expect(signals == [.roomActivity(roomId: "r42"), .sidebarChanged])
    }

    @Test func unknownCollectionsAreIgnored() {
        let message = StreamerSignalTransport.parse("""
            {"msg":"changed","collection":"stream-room-messages","id":"id",
             "fields":{"eventName":"r1","args":[{"_id":"m1","msg":"secret"}]}}
            """)!
        #expect(StreamerSignalTransport.signals(from: message).isEmpty)
    }
}

// MARK: - Transport session

@Suite struct StreamerSignalTransportTests {
    @Test func handshakeLoginSubscribeThenSignals() async throws {
        let socket = MockSignalSocket(script: [#"{"server_id":"0"}"#])
        let transport = StreamerSignalTransport(
            serverURL: serverURL,
            credentials: { AuthCredentials(authToken: "tok-1", userId: "uid-9") },
            socketFactory: MockSocketFactory(socket: socket),
            clock: TestClock())

        let stream = await transport.signals()
        var iterator = stream.makeAsyncIterator()

        // Connected + logged in + subscribed → first signal is health.
        let first = await iterator.next()
        #expect(first == .connected(true))

        // A live rooms-changed event flows through as routing hints.
        socket.feed("""
            {"msg":"changed","collection":"stream-notify-user","id":"id",
             "fields":{"eventName":"uid-9/rooms-changed",
                       "args":["updated",{"_id":"r7"}]}}
            """)
        let second = await iterator.next()
        #expect(second == .roomActivity(roomId: "r7"))
        let third = await iterator.next()
        #expect(third == .sidebarChanged)

        // The transport spoke proper DDP: connect, resume login, both subs.
        let sent = socket.sentFrames
        #expect(sent.contains { $0.contains(#""msg":"connect""#) })
        #expect(sent.contains { $0.contains(#""resume":"tok-1""#) })
        #expect(sent.contains { $0.contains("uid-9/subscriptions-changed") })
        #expect(sent.contains { $0.contains("uid-9/rooms-changed") })

        await transport.stop()
    }

    @Test func pingIsAnsweredWithPong() async throws {
        let socket = MockSignalSocket(script: [])
        let transport = StreamerSignalTransport(
            serverURL: serverURL,
            credentials: { AuthCredentials(authToken: "tok-1", userId: "uid-9") },
            socketFactory: MockSocketFactory(socket: socket),
            clock: TestClock())

        let stream = await transport.signals()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()   // .connected(true)

        socket.feed(#"{"msg":"ping"}"#)
        socket.feed("""
            {"msg":"changed","collection":"stream-notify-user","id":"id",
             "fields":{"eventName":"uid-9/subscriptions-changed","args":[]}}
            """)
        _ = await iterator.next()   // sidebarChanged, ordering barrier

        #expect(socket.sentFrames.contains { $0.contains(#""msg":"pong""#) })
        await transport.stop()
    }
}

// MARK: - Engine integration

@Suite struct EnginePushSignalTests {
    /// A hand-driven transport: the test yields signals directly.
    private final class FakeTransport: PushSignaling, @unchecked Sendable {
        let stream: AsyncStream<PushSignal>
        let continuation: AsyncStream<PushSignal>.Continuation

        init() {
            var continuation: AsyncStream<PushSignal>.Continuation?
            self.stream = AsyncStream { continuation = $0 }
            self.continuation = continuation!
        }

        func signals() async -> AsyncStream<PushSignal> { stream }
        func stop() async { continuation.finish() }
    }

    private func makeEngine(
        _ transport: MockHTTPTransport
    ) async -> (SyncEngine, FakeTransport) {
        let auth = AuthSession()
        await auth.set(AuthCredentials(authToken: "tok", userId: "uid-9"))
        let rest = RESTClient(
            serverURL: serverURL, transport: transport, auth: auth,
            clock: TestClock())
        let engine = SyncEngine(rest: rest, auth: auth, clock: TestClock())
        let fake = FakeTransport()
        await engine.attachPushSignals(fake)
        return (engine, fake)
    }

    @Test func sidebarSignalTriggersSidebarTick() async throws {
        let transport = MockHTTPTransport()
        transport.respond(path: "rooms.get", json: emptyDelta)
        transport.respond(path: "subscriptions.get", json: emptyDelta)

        // The engine must stay alive for the whole test: the push task holds
        // it weakly, so early ARC release silently drops signals.
        let (engine, fake) = await makeEngine(transport)
        defer { withExtendedLifetime(engine) {} }
        fake.continuation.yield(.sidebarChanged)

        // Wait until both delta requests landed.
        for _ in 0..<200 where transport.requests.count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let paths = transport.requests.compactMap { $0.url?.path() }
        #expect(paths.contains { $0.hasSuffix("rooms.get") })
        #expect(paths.contains { $0.hasSuffix("subscriptions.get") })
    }

    @Test func roomSignalTicksOnlyOpenRooms() async throws {
        let transport = MockHTTPTransport()
        transport.respond(path: "channels.messages", json: emptyPage)
        transport.respond(path: "chat.syncMessages", json: emptySync)

        let (engine, fake) = await makeEngine(transport)
        defer { withExtendedLifetime(engine) {} }
        try await engine.openRoom("r1", startPolling: false)

        fake.continuation.yield(.roomActivity(roomId: "closed-room"))
        fake.continuation.yield(.roomActivity(roomId: "r1"))

        for _ in 0..<200 where transport.requests.count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let syncRequests = transport.requests.filter {
            $0.url!.path().hasSuffix("chat.syncMessages")
        }
        #expect(syncRequests.count == 1)
        guard let syncRequest = syncRequests.first else { return }
        let query = URLComponents(
            url: syncRequest.url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "roomId" }?.value == "r1")
    }

    @Test func healthySignalStretchesPollingAndReconnectCatchesUp() async throws {
        let transport = MockHTTPTransport()
        transport.respond(path: "rooms.get", json: emptyDelta)
        transport.respond(path: "subscriptions.get", json: emptyDelta)

        let (engine, fake) = await makeEngine(transport)
        fake.continuation.yield(.connected(true))

        for _ in 0..<200 where transport.requests.count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        // Coming up triggers a catch-up sidebar tick and marks push healthy.
        #expect(await engine.pushHealthy)
        #expect(transport.requests.count >= 2)

        fake.continuation.yield(.connected(false))
        for _ in 0..<200 {
            if await !engine.pushHealthy { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await !engine.pushHealthy)
    }
}
