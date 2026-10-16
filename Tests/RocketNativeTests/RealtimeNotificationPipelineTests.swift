import Testing
import Foundation
@testable import RocketNative
@testable import RocketChatSDK

/// End-to-end over the realtime sidebar path: streamer frames (as captured
/// from a Rocket.Chat 8.6 server for a DM) → `StreamerTransport.events` →
/// `SyncEngine` → room store snapshots → `NotificationPlanner`. Guards the
/// cross-layer contract that broke banners: the stream splits counts and
/// last message into separate snapshots.
@MainActor
@Suite struct RealtimeNotificationPipelineTests {
    private static let selfId = "uid-carol"
    private static let dm = "dm-1"

    private static func subscriptionFrame(unread: Int, updatedAt: Int) -> String {
        """
        {"msg":"changed","collection":"stream-notify-user","id":"id","fields":{
         "eventName":"\(selfId)/subscriptions-changed","args":["updated",{
          "_id":"s-dm","rid":"\(dm)","t":"d","name":"rtbob","fname":"Bob Tester",
          "u":{"_id":"\(selfId)","username":"rtcarol"},"open":true,
          "unread":\(unread),"alert":true,"userMentions":0,"groupMentions":0,
          "ls":{"$date":1792085900000},"_updatedAt":{"$date":\(updatedAt)}}]}}
        """
    }

    private static func roomFrame(messageId: String, text: String, at ms: Int) -> String {
        """
        {"msg":"changed","collection":"stream-notify-user","id":"id","fields":{
         "eventName":"\(selfId)/rooms-changed","args":["updated",{
          "_id":"\(dm)","t":"d","usernames":["rtbob","rtcarol"],
          "uids":["uid-bob","\(selfId)"],"msgs":3,"lm":{"$date":\(ms)},
          "lastMessage":{"_id":"\(messageId)","rid":"\(dm)","msg":"\(text)",
           "ts":{"$date":\(ms)},"u":{"_id":"uid-bob","username":"rtbob","name":"Bob Tester"},
           "_updatedAt":{"$date":\(ms)},"md":[],"mentions":[],"channels":[],"urls":[]},
          "_updatedAt":{"$date":\(ms + 30)}}]}}
        """
    }

    /// Plays frames through the real decoder and engine, feeding each store
    /// snapshot to a planner the way `NotificationManager` does.
    private func play(_ frames: [String]) async throws -> [[NotificationPlanner.Event]] {
        let auth = AuthSession()
        let engine = SyncEngine(
            rest: RESTClient(
                serverURL: URL(string: "http://localhost:3000")!,
                transport: URLSessionTransport(), auth: auth, clock: SystemClock()),
            auth: auth, clock: SystemClock())
        var snapshots = await engine.roomStore.updates().makeAsyncIterator()
        var planner = NotificationPlanner()

        // Baseline: the DM with an older, already-seen message.
        await engine.handle(.roomChanged(Room(
            _id: Self.dm, t: .directMessage, uids: ["uid-bob", Self.selfId],
            lastMessage: Message(
                _id: "m0", rid: Self.dm, msg: "old", ts: Date(timeIntervalSince1970: 1),
                u: MiniUser(_id: "uid-bob", username: "rtbob", name: "Bob Tester")))))
        await engine.handle(.subscriptionChanged(Subscription(
            _id: "s-dm", rid: Self.dm, name: "rtbob", t: .directMessage, unread: 0)))
        _ = await snapshots.next()   // initial (empty) snapshot
        _ = await snapshots.next()   // room only (no subscription → not listed)
        let baseline = try #require(await snapshots.next())
        _ = planner.ingest(baseline, suppressedRoomId: nil, selfUserId: Self.selfId)

        var results: [[NotificationPlanner.Event]] = []
        for frame in frames {
            let message = try #require(StreamerTransport.parse(frame))
            let events = StreamerTransport.events(from: message)
            for event in events {
                await engine.handle(event)
            }
            // Exactly one store change per frame: each is its own snapshot.
            let snapshot = try #require(await snapshots.next())
            results.append(planner.ingest(
                snapshot, suppressedRoomId: nil, selfUserId: Self.selfId))
        }
        return results
    }

    @Test func dmOverTheStreamPostsOneBannerPerMessage() async throws {
        // Order and spacing as captured: subscription first, then room.
        let results = try await play([
            Self.subscriptionFrame(unread: 1, updatedAt: 1792085940681),
            Self.roomFrame(messageId: "m1", text: "ping 1", at: 1792085942807),
            Self.subscriptionFrame(unread: 2, updatedAt: 1792085942866),
            Self.roomFrame(messageId: "m2", text: "ping 2", at: 1792085944323),
        ])
        #expect(results.map(\.count) == [0, 1, 0, 1])
        #expect(results[1].first?.body == "ping 1")
        #expect(results[1].first?.title == "Bob Tester")
        #expect(results[3].first?.body == "ping 2")
    }

    @Test func roomRecordFirstAlsoPostsOneBanner() async throws {
        let results = try await play([
            Self.roomFrame(messageId: "m1", text: "ping 1", at: 1792085942807),
            Self.subscriptionFrame(unread: 1, updatedAt: 1792085942866),
        ])
        #expect(results.map(\.count) == [0, 1])
    }
}
