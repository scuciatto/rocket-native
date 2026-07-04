import Testing
import Foundation
@testable import RocketChatSDK

private func tempDatabasePath() -> String {
    FileManager.default.temporaryDirectory
        .appending(path: "rc-sdk-test-\(UUID().uuidString).sqlite").path()
}

private func msg(
    _ id: String, ts: TimeInterval, text: String = "hi", user: String = "ana"
) -> Message {
    Message(
        _id: id, rid: "room-1", msg: text,
        ts: Date(timeIntervalSince1970: ts),
        u: MiniUser(_id: "u-\(user)", username: user, name: nil))
}

@Suite struct SQLiteMessageStoreTests {
    @Test func persistsAcrossInstances() async throws {
        let path = tempDatabasePath()
        do {
            let store = try SQLiteMessageStore(path: path)
            await store.apply(
                delta: MessageDelta(
                    updated: [msg("a", ts: 1), msg("b", ts: 2, text: "**bold**")],
                    deleted: []),
                in: "room-1")
        }
        let reopened = try SQLiteMessageStore(path: path)
        let snapshot = await reopened.snapshot("room-1")
        #expect(snapshot.entries.map(\.id) == ["a", "b"])
        #expect(snapshot.entries[1].message.msg == "**bold**")
    }

    @Test func upsertsEditsAndAppliesDeletes() async throws {
        let store = try SQLiteMessageStore(path: tempDatabasePath())
        await store.apply(
            delta: MessageDelta(updated: [msg("a", ts: 1), msg("b", ts: 2)], deleted: []),
            in: "room-1")
        await store.apply(
            delta: MessageDelta(
                updated: [msg("b", ts: 2, text: "edited")],
                deleted: [DeletedMessage(_id: "a", _deletedAt: nil)]),
            in: "room-1")

        let snapshot = await store.snapshot("room-1")
        #expect(snapshot.entries.map(\.id) == ["b"])
        #expect(snapshot.entries[0].message.msg == "edited")
    }

    @Test func stalePendingBecomesFailedOnReload() async throws {
        let path = tempDatabasePath()
        do {
            let store = try SQLiteMessageStore(path: path)
            await store.insertPending(msg("local", ts: 5, user: "felipe"), in: "room-1")
            let snapshot = await store.snapshot("room-1")
            #expect(snapshot.entries[0].delivery == .sending)
        }
        // New launch: the send never confirmed.
        let reopened = try SQLiteMessageStore(path: path)
        let snapshot = await reopened.snapshot("room-1")
        #expect(snapshot.entries[0].delivery == .failed)
    }

    @Test func confirmFlipsPendingToSent() async throws {
        let store = try SQLiteMessageStore(path: tempDatabasePath())
        await store.insertPending(msg("local", ts: 5, user: "felipe"), in: "room-1")
        await store.confirm(
            messageId: "local", with: msg("local", ts: 5, user: "felipe"), in: "room-1")
        let snapshot = await store.snapshot("room-1")
        #expect(snapshot.entries[0].delivery == .sent)
    }

    @Test func snapshotWindowsToVisibleLimitButKeepsHistoryOnDisk() async throws {
        let store = try SQLiteMessageStore(path: tempDatabasePath(), windowLimit: 3)
        await store.apply(
            delta: MessageDelta(
                updated: (1...10).map { msg("m\($0)", ts: TimeInterval($0)) },
                deleted: []),
            in: "room-1")

        var snapshot = await store.snapshot("room-1")
        #expect(snapshot.entries.map(\.id) == ["m8", "m9", "m10"])
        // All ten remain cached for offset paging.
        #expect(await store.count("room-1") == 10)

        // Scroll-back widens the window.
        await store.prepend(older: [msg("m0", ts: 0)], in: "room-1")
        snapshot = await store.snapshot("room-1")
        #expect(snapshot.entries.count == 4)

        // Closing the room narrows it again; disk keeps everything.
        await store.trim("room-1", to: 2)
        snapshot = await store.snapshot("room-1")
        #expect(snapshot.entries.map(\.id) == ["m9", "m10"])
        #expect(await store.count("room-1") == 11)
    }

    @Test func threadWindowsDoNotCollideWithRoomWindows() async throws {
        let store = try SQLiteMessageStore(path: tempDatabasePath())
        let shared = msg("parent", ts: 1)
        await store.apply(delta: MessageDelta(updated: [shared], deleted: []), in: "room-1")
        await store.apply(
            delta: MessageDelta(updated: [shared, msg("reply", ts: 2)], deleted: []),
            in: SyncEngine.threadKey("parent"))

        #expect(await store.snapshot("room-1").entries.map(\.id) == ["parent"])
        #expect(await store.snapshot(SyncEngine.threadKey("parent")).entries.count == 2)
    }
}

@Suite struct SQLiteRoomStoreTests {
    @Test func persistsJoinAcrossInstances() async throws {
        let path = tempDatabasePath()
        do {
            let store = try SQLiteRoomStore(path: path)
            await store.apply(
                roomsUpdated: [Room(_id: "r1", t: .channel, name: "general")],
                roomsRemoved: [],
                subscriptionsUpdated: [Subscription(
                    _id: "s1", rid: "r1", name: "general", t: .channel, unread: 3)],
                subscriptionsRemoved: [])
        }
        let reopened = try SQLiteRoomStore(path: path)
        let list = await reopened.snapshot()
        #expect(list.count == 1)
        #expect(list[0].displayName == "general")
        #expect(list[0].unread == 3)
        #expect(await reopened.roomType("r1") == .channel)
    }

    @Test func removalsPersist() async throws {
        let path = tempDatabasePath()
        do {
            let store = try SQLiteRoomStore(path: path)
            await store.apply(
                roomsUpdated: [Room(_id: "r1", t: .channel, name: "general")],
                roomsRemoved: [],
                subscriptionsUpdated: [Subscription(_id: "s1", rid: "r1", t: .channel)],
                subscriptionsRemoved: [])
            await store.apply(
                roomsUpdated: [], roomsRemoved: [],
                subscriptionsUpdated: [], subscriptionsRemoved: ["r1"])
        }
        let reopened = try SQLiteRoomStore(path: path)
        #expect(await reopened.snapshot().isEmpty)
    }
}

@Suite struct SQLiteCacheSetupTests {
    /// Regression: URL.path() percent-encodes by default, which turned
    /// "Application Support" into "Application%20Support" and made SQLite
    /// fail with "unable to open database file".
    @Test func clientOpensCacheInDirectoryWithSpaces() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rc sdk cache \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = try RocketChatClient(
            serverURL: URL(string: "https://chat.example.com")!,
            cache: .sqlite(directory: directory),
            transport: MockHTTPTransport())

        // A write through a store proves the database really opened.
        await client.engine.messageStore.apply(
            delta: MessageDelta(updated: [msg("a", ts: 1)], deleted: []), in: "r1")
        #expect(await client.engine.messageStore.count("r1") == 1)
        #expect(FileManager.default.fileExists(
            atPath: client.cacheFileURL!.path(percentEncoded: false)))
    }
}

@Suite struct SQLiteSyncMarkTests {
    @Test func marksPersistAcrossInstances() async throws {
        let path = tempDatabasePath()
        let date = Date(timeIntervalSince1970: 1_700_000_000.5)
        do {
            let store = try SQLiteSyncMarkStore(path: path)
            await store.set(date, for: "rooms")
        }
        let reopened = try SQLiteSyncMarkStore(path: path)
        let mark = await reopened.mark(for: "rooms")
        #expect(mark != nil)
        #expect(abs(mark!.timeIntervalSince(date)) < 0.001)
        #expect(await reopened.mark(for: "missing") == nil)
    }

    @Test func engineResumesSidebarDeltaFromPersistedMarks() async throws {
        let path = tempDatabasePath()
        let markStore = try SQLiteSyncMarkStore(path: path)
        let transport = MockHTTPTransport()
        transport.respond(path: "rooms.get", json: """
            {"update": [{"_id": "r1", "t": "c", "name": "general",
              "_updatedAt": "2024-01-02T10:00:00.000Z"}], "remove": [], "success": true}
            """)
        transport.respond(path: "subscriptions.get", json: """
            {"update": [{"_id": "s1", "rid": "r1", "t": "c",
              "_updatedAt": "2024-01-02T10:00:05.000Z"}], "remove": [], "success": true}
            """)

        let auth = AuthSession()
        await auth.set(AuthCredentials(authToken: "tok", userId: "uid-9"))
        let clock = TestClock()
        let rest = RESTClient(
            serverURL: URL(string: "https://chat.example.com")!,
            transport: transport, auth: auth, clock: clock)
        let engine = SyncEngine(
            rest: rest, auth: auth, clock: clock, markStore: markStore)
        await engine.tickSidebar()

        // "Next launch": a fresh engine over the same mark store must resume
        // with updatedSince set from the persisted marks.
        transport.respond(path: "rooms.get", json: #"{"update": [], "remove": [], "success": true}"#)
        transport.respond(path: "subscriptions.get", json: #"{"update": [], "remove": [], "success": true}"#)
        let secondEngine = SyncEngine(
            rest: rest, auth: auth, clock: clock, markStore: markStore)
        await secondEngine.loadPersistedMarks()
        await secondEngine.tickSidebar()

        let lastTwo = transport.requests.suffix(2)
        let roomsRequest = lastTwo.first { $0.url!.path().hasSuffix("rooms.get") }
        let query = URLComponents(
            url: roomsRequest!.url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "updatedSince" }?.value
            == "2024-01-02T10:00:00.000Z")
    }
}
