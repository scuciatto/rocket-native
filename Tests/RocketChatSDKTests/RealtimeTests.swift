import Testing
import Foundation
@testable import RocketChatSDK

private let serverURL = URL(string: "https://chat.example.com")!
private let emptyPage = #"{"messages": [], "count": 0, "offset": 0, "total": 0, "success": true}"#
private let emptyDelta = #"{"update": [], "remove": [], "success": true}"#
private let emptySync = #"{"result": {"updated": [], "deleted": []}, "success": true}"#

private func message(
    _ id: String, rid: String = "r1", text: String = "hi",
    updatedAt: TimeInterval? = nil, tmid: String? = nil
) -> Message {
    Message(
        _id: id, rid: rid, msg: text,
        ts: Date(timeIntervalSince1970: 1_000_000),
        u: MiniUser(_id: "u2", username: "bob", name: "Bob"),
        _updatedAt: updatedAt.map(Date.init(timeIntervalSince1970:)),
        tmid: tmid)
}

/// Polls `condition` for up to ~1 s (actor hops make effects async).
private func eventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: - Scripted socket

/// Feeds scripted frames to the transport and records what it sends. It
/// answers the handshake like the server: `connected`, the login result,
/// and `ready` for subscriptions.
final class MockSignalSocket: SignalSocket, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sent: [String] = []
    private var incomingContinuation: AsyncStream<String>.Continuation?
    private var incomingIterator: AsyncStream<String>.AsyncIterator
    /// Sub ids answered with `nosub` instead of `ready`.
    var refusedSubs: Set<String> = []

    init(script: [String] = []) {
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

    /// Ends the incoming stream: the next receive throws (socket dropped).
    func finishIncoming() {
        incomingContinuation?.finish()
    }

    func connect() async throws {}

    func send(_ text: String) async throws {
        lock.withLock { sent.append(text) }
        guard let frame = StreamerTransport.parse(text) else { return }
        switch frame["msg"]?.stringValue {
        case "connect":
            feed(#"{"msg":"connected","session":"s1"}"#)
        case "method" where frame["method"]?.stringValue == "login":
            feed(#"{"msg":"result","id":"\#(StreamerTransport.loginId)","result":{"id":"uid-9"}}"#)
        case "sub":
            let id = frame["id"]?.stringValue ?? ""
            if refusedSubs.contains(id) {
                feed(#"{"msg":"nosub","id":"\#(id)","error":{"error":"not-allowed"}}"#)
            } else {
                feed(#"{"msg":"ready","subs":["\#(id)"]}"#)
            }
        default:
            break
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

    var sentJSON: [JSONValue] {
        sentFrames.compactMap(StreamerTransport.parse)
    }
}

/// Hands out sockets in order, one per connection attempt; the last one is
/// reused for any further attempts.
private final class MockSocketFactory: SignalSocketFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [MockSignalSocket]

    init(_ sockets: [MockSignalSocket]) {
        self.sockets = sockets
    }

    func makeSocket(url: URL) -> SignalSocket {
        lock.withLock { sockets.count > 1 ? sockets.removeFirst() : sockets[0] }
    }
}

private func makeTransport(_ sockets: MockSignalSocket...) -> StreamerTransport {
    StreamerTransport(
        serverURL: serverURL,
        credentials: { AuthCredentials(authToken: "tok-1", userId: "uid-9") },
        socketFactory: MockSocketFactory(sockets),
        clock: TestClock())
}

// MARK: - Frame reduction

@Suite struct RealtimeFrameReductionTests {
    private func changed(_ collection: String, eventName: String, args: String) -> JSONValue {
        StreamerTransport.parse("""
            {"msg":"changed","collection":"\(collection)","id":"id",
             "fields":{"eventName":"\(eventName)","args":\(args)}}
            """)!
    }

    @Test func subscriptionsChangedCarriesTheRecord() {
        let events = StreamerTransport.events(from: changed(
            "stream-notify-user", eventName: "uid-9/subscriptions-changed",
            args: #"["updated", {"_id":"s1","rid":"r1","unread":3,"_updatedAt":{"$date":1700000000000}}]"#))
        guard case .subscriptionChanged(let subscription) = events.first else {
            Issue.record("expected subscriptionChanged, got \(events)")
            return
        }
        #expect(events.count == 1)
        #expect(subscription.rid == "r1")
        #expect(subscription.unread == 3)
        #expect(subscription._updatedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func subscriptionRemovedCarriesRoomId() {
        let events = StreamerTransport.events(from: changed(
            "stream-notify-user", eventName: "uid-9/subscriptions-changed",
            args: #"["removed", {"_id":"s1","rid":"r1"}]"#))
        #expect(events == [.subscriptionRemoved(roomId: "r1")])
    }

    @Test func undecodableSubscriptionFallsBackToBell() {
        let events = StreamerTransport.events(from: changed(
            "stream-notify-user", eventName: "uid-9/subscriptions-changed",
            args: #"["updated", {"_id":"s1"}]"#))
        #expect(events == [.sidebarChanged])
    }

    @Test func roomsChangedCarriesRoomAndActivity() {
        let events = StreamerTransport.events(from: changed(
            "stream-notify-user", eventName: "uid-9/rooms-changed",
            args: #"["updated", {"_id": "r42", "t": "c", "msgs": 10}]"#))
        #expect(events == [
            .roomChanged(Room(_id: "r42", t: .channel, msgs: 10)),
            .roomActivity(roomId: "r42"),
        ])
    }

    @Test func roomRemovedAndMalformedRoom() {
        #expect(StreamerTransport.events(from: changed(
            "stream-notify-user", eventName: "uid-9/rooms-changed",
            args: #"["removed", {"_id": "r42"}]"#)) == [.roomRemoved(roomId: "r42")])
        #expect(StreamerTransport.events(from: changed(
            "stream-notify-user", eventName: "uid-9/rooms-changed",
            args: #"["updated", {"name": "no id"}]"#)) == [.sidebarChanged])
    }

    @Test func roomMessageDecodesWithMeteorDates() {
        let events = StreamerTransport.events(from: changed(
            "stream-room-messages", eventName: "r1",
            args: #"[{"_id":"m1","rid":"r1","msg":"hello","ts":{"$date":1700000000000},"u":{"_id":"u2","username":"bob"},"_updatedAt":{"$date":1700000001000},"tmid":"t1"}]"#))
        guard case .message(let roomId, let decoded) = events.first else {
            Issue.record("expected message, got \(events)")
            return
        }
        #expect(roomId == "r1")
        #expect(decoded.msg == "hello")
        #expect(decoded.tmid == "t1")
        #expect(decoded._updatedAt == Date(timeIntervalSince1970: 1_700_000_001))
    }

    @Test func undecodableRoomMessageFallsBackToActivity() {
        let events = StreamerTransport.events(from: changed(
            "stream-room-messages", eventName: "r1", args: #"[{"_id":"m1"}]"#))
        #expect(events == [.roomActivity(roomId: "r1")])
    }

    @Test func deleteMessage() {
        let events = StreamerTransport.events(from: changed(
            "stream-notify-room", eventName: "r1/deleteMessage", args: #"[{"_id":"m1"}]"#))
        #expect(events == [.messageDeleted(roomId: "r1", messageId: "m1")])
    }

    @Test func userActivityStartStopAndThread() {
        #expect(StreamerTransport.events(from: changed(
            "stream-notify-room", eventName: "r1/user-activity",
            args: #"["bob", ["user-typing"], {"tmid": "t1"}]"#))
            == [.typing(roomId: "r1", threadId: "t1", username: "bob", active: true)])
        #expect(StreamerTransport.events(from: changed(
            "stream-notify-room", eventName: "r1/user-activity",
            args: #"["bob", []]"#))
            == [.typing(roomId: "r1", threadId: nil, username: "bob", active: false)])
        // Legacy `typing` events are ignored (servers 4.0+ use user-activity).
        #expect(StreamerTransport.events(from: changed(
            "stream-notify-room", eventName: "r1/typing", args: #"["bob", true]"#)).isEmpty)
    }

    @Test func presenceMapsStatusCodes() {
        let frame = StreamerTransport.parse("""
            {"msg":"changed","collection":"stream-user-presence","id":"id",
             "fields":{"uid":"u2","eventName":"u2","args":[["bob",3,"in a meeting"]]}}
            """)!
        #expect(StreamerTransport.events(from: frame) == [.presence(UserPresence(
            userId: "u2", username: "bob", status: .busy, statusText: "in a meeting"))])
        #expect(PresenceStatus(code: 0) == .offline)
        #expect(PresenceStatus(code: 1) == .online)
        #expect(PresenceStatus(code: 2) == .away)
        #expect(PresenceStatus(code: 9) == .unknown)
    }

    @Test func unknownCollectionsAreIgnored() {
        #expect(StreamerTransport.events(from: changed(
            "stream-notify-all", eventName: "public-settings-changed", args: "[]")).isEmpty)
    }
}

// MARK: - Transport session

@Suite struct StreamerTransportTests {
    @Test func handshakeLoginsSubscribesAndReportsHealth() async throws {
        let socket = MockSignalSocket(script: [#"{"server_id":"0"}"#])
        let transport = makeTransport(socket)
        var events = await transport.events().makeAsyncIterator()

        #expect(await events.next() == .connected(true))

        let sent = socket.sentJSON
        #expect(sent.contains { $0["msg"] == "connect" })
        #expect(sent.contains {
            $0["method"] == "login" && $0["params"]?.arrayValue?.first?["resume"] == "tok-1"
        })
        let subs = sent.filter { $0["msg"] == "sub" }
        #expect(subs.map { $0["params"]?.arrayValue?.first } == [
            "uid-9/subscriptions-changed", "uid-9/rooms-changed",
        ])

        // A live payload flows through.
        socket.feed("""
            {"msg":"changed","collection":"stream-notify-user","id":"id",
             "fields":{"eventName":"uid-9/rooms-changed","args":["removed",{"_id":"r7"}]}}
            """)
        #expect(await events.next() == .roomRemoved(roomId: "r7"))
        await transport.stop()
    }

    @Test func watchingARoomSubscribesItsStreamsAndGoesLive() async throws {
        let socket = MockSignalSocket()
        let transport = makeTransport(socket)
        var events = await transport.events().makeAsyncIterator()
        #expect(await events.next() == .connected(true))

        await transport.watchRoom("r1")
        #expect(await events.next() == .roomLive(roomId: "r1", true))
        let params = socket.sentJSON
            .filter { $0["msg"] == "sub" }
            .compactMap { $0["params"]?.arrayValue?.first?.stringValue }
        #expect(params.suffix(3) == ["r1", "r1/deleteMessage", "r1/user-activity"])

        await transport.unwatchRoom("r1")
        let unsubs = socket.sentJSON.filter { $0["msg"] == "unsub" }
            .compactMap { $0["id"]?.stringValue }
        #expect(unsubs == StreamerTransport.roomSubIds("r1"))
        await transport.stop()
    }

    @Test func refusedRoomSubscriptionIsNotLive() async throws {
        let socket = MockSignalSocket()
        socket.refusedSubs = ["room-msg-secret"]
        let transport = makeTransport(socket)
        var events = await transport.events().makeAsyncIterator()
        #expect(await events.next() == .connected(true))

        await transport.watchRoom("secret")
        #expect(await events.next() == .roomLive(roomId: "secret", false))
        await transport.stop()
    }

    @Test func reconnectReplaysWatchedRoomsAndPresence() async throws {
        let first = MockSignalSocket()
        let second = MockSignalSocket()
        let transport = makeTransport(first, second)
        // Desired state set before the socket is even up.
        await transport.watchRoom("r1")
        await transport.watchPresence(added: ["u2", "u3"], removed: [])

        var events = await transport.events().makeAsyncIterator()
        #expect(await events.next() == .connected(true))
        first.finishIncoming()   // socket drops
        // Drain until the second session is healthy again.
        while let event = await events.next(), event != .connected(true) {}

        for socket in [first, second] {
            let sent = socket.sentJSON
            #expect(sent.contains { $0["name"] == "stream-room-messages"
                && $0["params"]?.arrayValue?.first == "r1" })
            let presence = sent.first { $0["name"] == "stream-user-presence" }
            #expect(presence?["params"]?.arrayValue?.last?["added"] == .array(["u2", "u3"]))
        }
        await transport.stop()
    }

    @Test func typingWriteIsAStreamNotifyRoomFrame() async throws {
        let socket = MockSignalSocket()
        let transport = makeTransport(socket)
        var events = await transport.events().makeAsyncIterator()
        #expect(await events.next() == .connected(true))

        await transport.sendTyping(roomId: "r1", threadId: "t1", name: "me", active: true)
        await transport.sendTyping(roomId: "r1", threadId: nil, name: "me", active: false)

        let writes = socket.sentJSON.filter { $0["method"] == "stream-notify-room" }
        #expect(writes.map { $0["params"] } == [
            .array(["r1/user-activity", "me", .array(["user-typing"]), .object(["tmid": "t1"])]),
            .array(["r1/user-activity", "me", .array([]), .object([:])]),
        ])
        await transport.stop()
    }

    @Test func pingIsAnsweredWithPong() async throws {
        let socket = MockSignalSocket()
        let transport = makeTransport(socket)
        var events = await transport.events().makeAsyncIterator()
        #expect(await events.next() == .connected(true))

        socket.feed(#"{"msg":"ping"}"#)
        socket.feed("""
            {"msg":"changed","collection":"stream-notify-room","id":"id",
             "fields":{"eventName":"r1/deleteMessage","args":[{"_id":"m1"}]}}
            """)
        _ = await events.next()   // ordering barrier

        #expect(socket.sentJSON.contains { $0["msg"] == "pong" })
        await transport.stop()
    }
}

// MARK: - Engine integration

/// A hand-driven transport: tests yield events and inspect calls.
private final class FakeTransport: RealtimeTransport, @unchecked Sendable {
    let stream: AsyncStream<RealtimeEvent>
    let continuation: AsyncStream<RealtimeEvent>.Continuation
    private let lock = NSLock()
    private var _watched: [String] = []
    private var _presence: [String] = []
    private var _typing: [(String, String?, String, Bool)] = []

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: RealtimeEvent.self)
    }

    var watched: [String] { lock.withLock { _watched } }
    var presence: [String] { lock.withLock { _presence } }
    var typing: [(String, String?, String, Bool)] { lock.withLock { _typing } }

    func events() async -> AsyncStream<RealtimeEvent> { stream }
    func stop() async { continuation.finish() }
    func watchRoom(_ roomId: String) async { lock.withLock { _watched.append(roomId) } }
    func unwatchRoom(_ roomId: String) async { lock.withLock { _watched.removeAll { $0 == roomId } } }
    func watchPresence(added: [String], removed: [String]) async {
        lock.withLock { _presence += added }
    }
    func sendTyping(roomId: String, threadId: String?, name: String, active: Bool) async {
        lock.withLock { _typing.append((roomId, threadId, name, active)) }
    }
}

/// `now` moves only when told; sleeps last until cancelled.
private final class ManualClock: RESTClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_000_000)

    var now: Date { lock.withLock { _now } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { _now = _now.addingTimeInterval(seconds) }
    }

    func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .seconds(3600))
    }
}

@Suite struct EngineRealtimeTests {
    private func makeEngine(
        _ http: MockHTTPTransport,
        clock: RESTClock = TestClock(),
        messageStore: MessageStoring = InMemoryMessageStore()
    ) async -> (SyncEngine, FakeTransport) {
        let auth = AuthSession()
        await auth.set(AuthCredentials(authToken: "tok", userId: "uid-9"))
        await auth.setProfile(UserProfile(_id: "uid-9", username: "me", name: "Me Myself"))
        let rest = RESTClient(serverURL: serverURL, transport: http, auth: auth, clock: clock)
        let engine = SyncEngine(
            rest: rest, auth: auth, clock: clock, messageStore: messageStore)
        let fake = FakeTransport()
        await engine.attachRealtime(fake)
        return (engine, fake)
    }

    @Test func openingARoomWatchesIt() async throws {
        let http = MockHTTPTransport()
        http.respond(path: "channels.messages", json: emptyPage)
        let (engine, fake) = await makeEngine(http)
        try await engine.openRoom("r1", startPolling: false)
        #expect(fake.watched == ["r1"])
        await engine.closeRoom("r1")
        #expect(fake.watched.isEmpty)
    }

    @Test func streamedMessageLandsWithoutRESTAndKeepsTheMark() async throws {
        let http = MockHTTPTransport()
        http.respond(path: "channels.messages", json: emptyPage)
        let (engine, _) = await makeEngine(http)
        try await engine.openRoom("r1", startPolling: false)
        let requestsAfterOpen = http.requests.count

        await engine.handle(.message(roomId: "r1", message("m1", updatedAt: 2_000_000)))
        #expect(await engine.messageStore.snapshot("r1").entries.map(\.id) == ["m1"])
        #expect(http.requests.count == requestsAfterOpen)

        // The next REST tick still starts from the REST mark (open time),
        // not from the streamed message's timestamp.
        http.respond(path: "chat.syncMessages", json: emptySync)
        await engine.tickRoom("r1")
        let query = URLComponents(url: http.requests.last!.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "lastUpdate" }?.value
        #expect(query == RCJSON.syncTimestamp(Date(timeIntervalSince1970: 1_000_000)))
    }

    @Test func threadRepliesRouteToTheOpenThread() async throws {
        let http = MockHTTPTransport()
        http.respond(path: "channels.messages", json: emptyPage)
        http.respond(path: "chat.getThreadMessages", json: emptyPage)
        let (engine, _) = await makeEngine(http)
        try await engine.openRoom("r1", startPolling: false)
        try await engine.openThread("t1", roomId: "r1", startPolling: false)

        await engine.handle(.message(roomId: "r1", message("m2", tmid: "t1")))
        #expect(await engine.messageStore.snapshot(SyncEngine.threadKey("t1"))
            .entries.map(\.id) == ["m2"])

        await engine.handle(.messageDeleted(roomId: "r1", messageId: "m2"))
        #expect(await engine.messageStore.snapshot(SyncEngine.threadKey("t1")).entries.isEmpty)
        #expect(await engine.messageStore.snapshot("r1").entries.isEmpty)
    }

    @Test func liveRoomsSkipTheActivityTick() async throws {
        let http = MockHTTPTransport()
        http.respond(path: "channels.messages", json: emptyPage)
        let (engine, _) = await makeEngine(http)
        try await engine.openRoom("r1", startPolling: false)
        let requestsAfterOpen = http.requests.count

        await engine.handle(.roomLive(roomId: "r1", true))
        await engine.handle(.roomActivity(roomId: "r1"))
        #expect(http.requests.count == requestsAfterOpen)

        // Not live (e.g. socket dropped): the bell falls back to REST.
        await engine.handle(.roomLive(roomId: "r1", false))
        http.respond(path: "chat.syncMessages", json: emptySync)
        await engine.handle(.roomActivity(roomId: "r1"))
        #expect(http.requests.count == requestsAfterOpen + 1)
    }

    @Test func sidebarPayloadsApplyWithoutREST() async throws {
        let http = MockHTTPTransport()
        let (engine, _) = await makeEngine(http)
        await engine.handle(.roomChanged(Room(_id: "r1", t: .channel, name: "general")))
        await engine.handle(.subscriptionChanged(Subscription(
            _id: "s1", rid: "r1", name: "general", unread: 4)))
        let summary = await engine.roomStore.snapshot().first
        #expect(summary?.unread == 4)
        #expect(summary?.displayName == "general")
        #expect(http.requests.isEmpty)

        await engine.handle(.subscriptionRemoved(roomId: "r1"))
        #expect(await engine.roomStore.snapshot().isEmpty)
    }

    @Test func connectingCatchesUpOverREST() async throws {
        let http = MockHTTPTransport()
        http.respond(path: "rooms.get", json: emptyDelta)
        http.respond(path: "subscriptions.get", json: emptyDelta)
        let (engine, fake) = await makeEngine(http)

        fake.continuation.yield(.connected(true))
        try await eventually { await engine.realtimeHealthy && http.requests.count >= 2 }
        #expect(await engine.realtimeHealthy)
        #expect(http.requests.count == 2)

        fake.continuation.yield(.connected(false))
        try await eventually { await !engine.realtimeHealthy }
        #expect(await !engine.realtimeHealthy)
    }

    @Test func othersTypingIsTrackedButNotOurselves() async throws {
        let http = MockHTTPTransport()
        let (engine, _) = await makeEngine(http)
        await engine.handle(.typing(roomId: "r1", threadId: nil, username: "bob", active: true))
        await engine.handle(.typing(roomId: "r1", threadId: nil, username: "me", active: true))
        await engine.handle(.typing(roomId: "r1", threadId: nil, username: "Me Myself", active: true))
        await engine.handle(.typing(roomId: "r1", threadId: "t1", username: "ann", active: true))
        #expect(await engine.typing.typists(roomId: "r1", threadId: nil) == ["bob"])
        #expect(await engine.typing.typists(roomId: "r1", threadId: "t1") == ["ann"])

        // A dropped socket means no stop events will come.
        await engine.handle(.connected(false))
        #expect(await engine.typing.typists(roomId: "r1", threadId: nil).isEmpty)
    }

    @Test func outgoingTypingIsThrottledAndStops() async throws {
        let http = MockHTTPTransport()
        http.respond(
            path: "settings.public",
            json: #"{"settings":[{"_id":"UI_Use_Real_Name","value":true}],"success":true}"#)
        let clock = ManualClock()
        let (engine, fake) = await makeEngine(http, clock: clock)

        await engine.noteTyping(roomId: "r1", threadId: nil)
        await engine.noteTyping(roomId: "r1", threadId: nil)   // within 3 s: no resend
        clock.advance(by: 3)
        await engine.noteTyping(roomId: "r1", threadId: nil)   // resend
        await engine.stopTyping(roomId: "r1", threadId: nil)
        await engine.stopTyping(roomId: "r1", threadId: nil)   // already stopped: no-op

        // UI_Use_Real_Name on → broadcast under the display name; the
        // setting is read once.
        #expect(fake.typing.map(\.2) == ["Me Myself", "Me Myself", "Me Myself"])
        #expect(fake.typing.map(\.3) == [true, true, false])
        #expect(http.requests.count == 1)
    }

    @Test func adoptedTokenSessionLoadsItsProfileForTyping() async throws {
        // Like `adopt(credentials:)` (PAT sign-in): credentials, no profile.
        let http = MockHTTPTransport()
        http.respond(path: "me", json: #"{"_id":"uid-9","username":"carol","success":true}"#)
        http.respond(
            path: "settings.public",
            json: #"{"settings":[{"_id":"UI_Use_Real_Name","value":false}],"success":true}"#)
        let auth = AuthSession()
        await auth.set(AuthCredentials(authToken: "tok", userId: "uid-9"))
        let clock = ManualClock()
        let rest = RESTClient(serverURL: serverURL, transport: http, auth: auth, clock: clock)
        let engine = SyncEngine(rest: rest, auth: auth, clock: clock)
        let fake = FakeTransport()
        await engine.attachRealtime(fake)

        await engine.noteTyping(roomId: "r1", threadId: nil)
        // Broadcast under the username the server checks, not the user id.
        #expect(fake.typing.map(\.2) == ["carol"])
        // And our own echo is recognized.
        await engine.handle(.typing(roomId: "r1", threadId: nil, username: "carol", active: true))
        #expect(await engine.typing.typists(roomId: "r1", threadId: nil).isEmpty)
        await engine.stopTyping(roomId: "r1", threadId: nil)
    }

    @Test func presenceIsSeededOverRESTThenWatched() async throws {
        let http = MockHTTPTransport()
        http.respond(
            path: "users.presence",
            json: #"{"users":[{"_id":"u2","username":"bob","status":"away"}],"full":false,"success":true}"#)
        let (engine, fake) = await makeEngine(http)

        await engine.trackPresence(["u2"])
        await engine.trackPresence(["u2"])   // already tracked: no second request
        #expect(http.requests.count == 1)
        #expect(fake.presence == ["u2"])
        #expect(await engine.presence.snapshot()["u2"]?.status == .away)

        await engine.handle(.presence(UserPresence(userId: "u2", status: .online)))
        #expect(await engine.presence.snapshot()["u2"]?.status == .online)
    }
}

// MARK: - Store races and typing expiry

@Suite struct RealtimeConvergenceTests {
    @Test(arguments: ["memory", "sqlite"])
    func staleRESTRecordDoesNotRegressAStreamedOne(store kind: String) async throws {
        let store: MessageStoring = kind == "memory"
            ? InMemoryMessageStore()
            : try SQLiteMessageStore(path: FileManager.default.temporaryDirectory
                .appending(path: "rc-realtime-\(UUID().uuidString).sqlite").path())

        // Stream delivers the edit (T2) before an in-flight REST delta (T1).
        await store.apply(delta: MessageDelta(
            updated: [message("m1", text: "edited", updatedAt: 2_000)], deleted: []), in: "r1")
        await store.apply(delta: MessageDelta(
            updated: [message("m1", text: "original", updatedAt: 1_000)], deleted: []), in: "r1")
        #expect(await store.snapshot("r1").entries.first?.message.msg == "edited")

        // A genuinely newer record still applies.
        await store.apply(delta: MessageDelta(
            updated: [message("m1", text: "edited again", updatedAt: 3_000)], deleted: []), in: "r1")
        #expect(await store.snapshot("r1").entries.first?.message.msg == "edited again")
    }

    @Test func staleSubscriptionDoesNotRegress() async {
        let store = InMemoryRoomStore()
        await store.apply(
            roomsUpdated: [], roomsRemoved: [],
            subscriptionsUpdated: [Subscription(
                _id: "s1", rid: "r1", unread: 0, _updatedAt: Date(timeIntervalSince1970: 2_000))],
            subscriptionsRemoved: [])
        await store.apply(
            roomsUpdated: [], roomsRemoved: [],
            subscriptionsUpdated: [Subscription(
                _id: "s1", rid: "r1", unread: 5, _updatedAt: Date(timeIntervalSince1970: 1_000))],
            subscriptionsRemoved: [])
        #expect(await store.snapshot().first?.unread == 0)
    }

    @Test func typistsExpireWithoutAStop() async throws {
        // TestClock sleeps return at once (advancing `now`), so the expiry
        // timer fires right after the start event.
        let tracker = TypingTracker(clock: TestClock(), ttl: 10)
        var updates = await tracker.updates(roomId: "r1", threadId: nil).makeAsyncIterator()
        #expect(await updates.next() == [])
        await tracker.apply(roomId: "r1", threadId: nil, name: "bob", active: true)
        #expect(await updates.next() == ["bob"])
        #expect(await updates.next() == [])
    }

    @Test func typistsKeepArrivalOrderAndStopRemoves() async {
        let tracker = TypingTracker(clock: ManualClock(), ttl: 10)
        await tracker.apply(roomId: "r1", threadId: nil, name: "bob", active: true)
        await tracker.apply(roomId: "r1", threadId: nil, name: "ann", active: true)
        await tracker.apply(roomId: "r1", threadId: nil, name: "bob", active: true)
        #expect(await tracker.typists(roomId: "r1", threadId: nil) == ["bob", "ann"])
        await tracker.apply(roomId: "r1", threadId: nil, name: "bob", active: false)
        #expect(await tracker.typists(roomId: "r1", threadId: nil) == ["ann"])
    }
}
