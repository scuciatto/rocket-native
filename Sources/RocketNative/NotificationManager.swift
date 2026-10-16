import AppKit
import UserNotifications
import RocketChatSDK

/// Local notifications + Dock badge across all signed-in workspaces, driven
/// by each account's room-list snapshots (REST sidebar ticks and realtime
/// sidebar records alike). `NotificationPlanner` turns a grown
/// unread/mention count with a fresh last message into a banner, however
/// the two facts are split across snapshots.
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
            var planner = NotificationPlanner()
            for await rooms in await client.roomListUpdates() {
                guard let self else { return }
                self.roomsByAccount[accountId] = rooms
                self.updateDockBadge()
                let visibleRoomId = (self.appActive && self.activeAccountId == accountId)
                    ? self.activeRoomId : nil
                let events = planner.ingest(
                    rooms, suppressedRoomId: visibleRoomId, selfUserId: selfUserId)
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

    // MARK: - Dock badge (pure, kept separate for testability)

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

    private func post(_ event: NotificationPlanner.Event, accountId: String) {
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
