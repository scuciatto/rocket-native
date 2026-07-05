import AppKit
import UserNotifications
import RocketChatSDK

/// Local notifications + Dock badge across all signed-in workspaces, driven
/// entirely by each account's sidebar poll: room-list snapshots are diffed
/// against the previous one, so a grown unread/mention count with a fresh
/// last message becomes a banner. This is the REST-only design — there is no
/// push channel to subscribe to.
@MainActor
@Observable
final class NotificationManager {
    struct PendingSelection: Equatable {
        var accountId: String
        var roomId: String
    }

    /// Room the user is currently viewing (on the active account) — its
    /// messages never notify while the app is frontmost.
    var activeAccountId: String?
    var activeRoomId: String?
    var appActive = true
    /// Set when the user clicks a notification; MainWindow consumes it to
    /// switch to the account and select the room.
    var pendingSelection: PendingSelection?

    private var tasks: [String: Task<Void, Never>] = [:]
    private var roomsByAccount: [String: [RoomSummary]] = [:]
    private let delegate = Delegate()

    init() {
        delegate.onSelected = { [weak self] accountId, roomId in
            Task { @MainActor in
                self?.pendingSelection = PendingSelection(
                    accountId: accountId, roomId: roomId)
            }
        }
        UNUserNotificationCenter.current().delegate = delegate
    }

    func register(accountId: String, client: RocketChatClient, selfUserId: String) {
        unregister(accountId: accountId)
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]) { _, _ in }
        tasks[accountId] = Task { [weak self] in
            var previous: [String: RoomSummary] = [:]
            var isFirstSnapshot = true
            for await rooms in await client.roomListUpdates() {
                guard let self else { return }
                self.roomsByAccount[accountId] = rooms
                self.updateDockBadge()
                let before = previous
                previous = Dictionary(uniqueKeysWithValues: rooms.map { ($0.id, $0) })
                // The first snapshot is baseline state, not news.
                if isFirstSnapshot {
                    isFirstSnapshot = false
                    continue
                }
                let visibleRoomId = (self.appActive && self.activeAccountId == accountId)
                    ? self.activeRoomId : nil
                let events = Self.plan(
                    previous: before, current: rooms,
                    suppressedRoomId: visibleRoomId,
                    selfUserId: selfUserId)
                for event in events {
                    self.post(event, accountId: accountId)
                }
            }
        }
    }

    func unregister(accountId: String) {
        tasks[accountId]?.cancel()
        tasks[accountId] = nil
        roomsByAccount[accountId] = nil
        updateDockBadge()
    }

    func stopAll() {
        for accountId in tasks.keys {
            tasks[accountId]?.cancel()
        }
        tasks = [:]
        roomsByAccount = [:]
        NSApp.dockTile.badgeLabel = ""
    }

    // MARK: - Per-account badge (for the server rail)

    struct AccountBadge: Equatable {
        var personal: Int
        var hasUnread: Bool
    }

    func badge(for accountId: String) -> AccountBadge {
        let rooms = roomsByAccount[accountId] ?? []
        return AccountBadge(
            personal: Self.personalCount(rooms),
            hasUnread: rooms.contains { $0.unread > 0 || $0.alert })
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
    /// `suppressedRoomId` is the room currently on screen, when its account
    /// is the visible one and the app is frontmost.
    static func plan(
        previous: [String: RoomSummary], current: [RoomSummary],
        suppressedRoomId: String?, selfUserId: String?
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
            guard room.id != suppressedRoomId else { return nil }

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

    /// Dock badge across all workspaces: things that need *you* (mentions +
    /// DM unreads) as a number; a dot when only channel chatter is unread.
    static func dockBadgeLabel(accountRooms: [[RoomSummary]]) -> String {
        let personal = accountRooms.reduce(0) { $0 + personalCount($1) }
        if personal > 0 { return "\(personal)" }
        let anyUnread = accountRooms.contains { rooms in
            rooms.contains { $0.unread > 0 || $0.alert }
        }
        return anyUnread ? "•" : ""
    }

    private static func personalCount(_ rooms: [RoomSummary]) -> Int {
        rooms.reduce(0) { total, room in
            total + room.mentions + (room.type == .directMessage ? room.unread : 0)
        }
    }

    // MARK: - Delivery

    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = Self.dockBadgeLabel(
            accountRooms: Array(roomsByAccount.values))
    }

    private func post(_ event: Event, accountId: String) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        if let subtitle = event.subtitle {
            content.subtitle = subtitle
        }
        content.body = event.body
        if event.sound {
            content.sound = .default
        }
        content.userInfo = ["roomId": event.roomId, "accountId": accountId]
        content.threadIdentifier = "\(accountId)/\(event.roomId)"
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// UNUserNotificationCenter's delegate must be an NSObject.
    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        var onSelected: (@Sendable (String, String) -> Void)?

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
            let userInfo = response.notification.request.content.userInfo
            if let roomId = userInfo["roomId"] as? String,
               let accountId = userInfo["accountId"] as? String {
                onSelected?(accountId, roomId)
            }
        }
    }
}
