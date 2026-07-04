import AppKit
import UserNotifications
import RocketChatSDK

/// Local notifications + Dock badge, driven entirely by the sidebar poll:
/// each room-list snapshot is diffed against the previous one, so a grown
/// unread/mention count with a fresh last message becomes a banner. This is
/// the REST-only design — there is no push channel to subscribe to.
@MainActor
@Observable
final class NotificationManager {
    /// Room the user is currently viewing — its messages never notify while
    /// the app is frontmost.
    var activeRoomId: String?
    var appActive = true
    /// Set when the user clicks a notification; MainWindow consumes it to
    /// select the room.
    var pendingRoomSelection: String?

    private var selfUserId: String?
    private var observation: Task<Void, Never>?
    private var previousByRoom: [String: RoomSummary] = [:]
    private let delegate = Delegate()

    init() {
        delegate.onRoomSelected = { [weak self] roomId in
            Task { @MainActor in self?.pendingRoomSelection = roomId }
        }
        UNUserNotificationCenter.current().delegate = delegate
    }

    func start(client: RocketChatClient, selfUserId: String) {
        stop()
        self.selfUserId = selfUserId
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]) { _, _ in }
        observation = Task { [weak self] in
            var isFirstSnapshot = true
            for await rooms in await client.roomListUpdates() {
                guard let self else { return }
                self.updateBadge(rooms)
                let previous = self.previousByRoom
                self.previousByRoom = Dictionary(
                    uniqueKeysWithValues: rooms.map { ($0.id, $0) })
                // The first snapshot is baseline state, not news.
                if isFirstSnapshot {
                    isFirstSnapshot = false
                    continue
                }
                let events = Self.plan(
                    previous: previous, current: rooms,
                    activeRoomId: self.activeRoomId,
                    appActive: self.appActive,
                    selfUserId: self.selfUserId)
                for event in events {
                    self.post(event)
                }
            }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
        previousByRoom = [:]
        NSApp.dockTile.badgeLabel = ""
    }

    // MARK: - Planning (pure, kept separate for testability)

    struct Event {
        var roomId: String
        var title: String
        var subtitle: String?
        var body: String
        var sound: Bool
    }

    /// Decides which rooms deserve a banner given two consecutive snapshots.
    static func plan(
        previous: [String: RoomSummary], current: [RoomSummary],
        activeRoomId: String?, appActive: Bool, selfUserId: String?
    ) -> [Event] {
        current.compactMap { room in
            guard let last = room.lastMessage else { return nil }
            let before = previous[room.id]
            let unreadGrew = room.unread > (before?.unread ?? 0)
            let mentionsGrew = room.mentions > (before?.mentions ?? 0)
            guard unreadGrew || mentionsGrew else { return nil }
            // Only notify for an actual new message, not read-state churn.
            guard last.id != before?.lastMessage?.id else { return nil }
            // Never for own messages, and not for the room on screen.
            guard last.u._id != selfUserId else { return nil }
            if appActive && room.id == activeRoomId { return nil }

            let sender = last.u.name ?? last.u.username ?? "Someone"
            let text = last.msg.isEmpty ? "Sent an attachment" : String(last.msg.prefix(140))
            let isDirect = room.type == .directMessage
            return Event(
                roomId: room.id,
                title: isDirect ? sender : room.displayName,
                subtitle: isDirect ? nil : sender,
                body: text,
                sound: isDirect || mentionsGrew)
        }
    }

    /// Dock badge: things that need *you* (mentions + DM unreads) as a
    /// number; a dot when only channel chatter is unread.
    static func badgeLabel(for rooms: [RoomSummary]) -> String {
        let personal = rooms.reduce(0) { total, room in
            total + room.mentions + (room.type == .directMessage ? room.unread : 0)
        }
        if personal > 0 { return "\(personal)" }
        return rooms.contains { $0.unread > 0 || $0.alert } ? "•" : ""
    }

    // MARK: - Delivery

    private func updateBadge(_ rooms: [RoomSummary]) {
        NSApp.dockTile.badgeLabel = Self.badgeLabel(for: rooms)
    }

    private func post(_ event: Event) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        if let subtitle = event.subtitle {
            content.subtitle = subtitle
        }
        content.body = event.body
        if event.sound {
            content.sound = .default
        }
        content.userInfo = ["roomId": event.roomId]
        content.threadIdentifier = event.roomId
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// UNUserNotificationCenter's delegate must be an NSObject.
    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        var onRoomSelected: (@Sendable (String) -> Void)?

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .sound]
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse
        ) async {
            if let roomId = response.notification.request.content
                .userInfo["roomId"] as? String {
                onRoomSelected?(roomId)
            }
        }
    }
}
