import SwiftUI
import RocketChatSDK

struct MainWindow: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        @Bindable var session = session
        HStack(spacing: 0) {
            // Only show the rail once a second server could matter; a single
            // server keeps the uncluttered v1 layout.
            if session.accounts.count > 1 {
                ServerRail()
                Divider()
            }
            if let account = session.activeAccount {
                WorkspaceView(account: account)
                    .id(account.id)   // fresh models per workspace
            }
        }
        .sheet(isPresented: $session.showAddServer) {
            LoginView(isSheet: true)
        }
        .sheet(item: twoFactorRequest) { request in
            TwoFactorSheet(
                challenge: request.challenge,
                subtitle: session.accounts.count > 1 ? request.accountName : nil,
                notice: session.twoFactor.notice,
                isVerifying: session.twoFactor.isVerifying,
                onSubmit: { session.twoFactor.submit(code: $0) },
                onCancel: { session.twoFactor.cancel() },
                onResend: { Task { await session.resendTwoFactorEmail(for: request) } })
        }
        .onChange(of: session.activeAccountId) { _, accountId in
            session.notifications.activeAccountId = accountId
            session.notifications.activeRoomId = session.activeAccount?.selectedRoomId
        }
        .onChange(of: session.notifications.pendingSelection) { _, selection in
            // A clicked notification routes to its workspace and room.
            guard let selection else { return }
            session.activeAccountId = selection.accountId
            session.accounts.first { $0.id == selection.accountId }?
                .selectedRoomId = selection.roomId
            session.notifications.pendingSelection = nil
        }
        .task {
            session.notifications.activeAccountId = session.activeAccount?.id
        }
    }

    /// Mid-session 2FA prompt; a system dismissal counts as cancel.
    private var twoFactorRequest: Binding<TwoFactorPresenter.Request?> {
        Binding(
            get: { session.twoFactor.current },
            set: { if $0 == nil { session.twoFactor.cancel() } })
    }
}

/// One workspace's split view: sidebar (room list) + room detail.
struct WorkspaceView: View {
    @Environment(AppSession.self) private var session
    @Bindable var account: ServerAccount
    @State private var model = RoomListModel()
    @State private var showGlobalSearch = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                rooms: model.rooms, presence: model.presence,
                selection: $account.selectedRoomId)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let roomId = account.selectedRoomId,
               let room = model.rooms.first(where: { $0.id == roomId }) {
                RoomView(room: room)
                    .id(roomId)   // fresh view (and handle) per room
            } else {
                ContentUnavailableView(
                    "No Room Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Choose a room from the sidebar."))
            }
        }
        .task {
            await model.observe(account.client)
        }
        .onChange(of: account.selectedRoomId) { _, roomId in
            session.notifications.activeRoomId = roomId
        }
        .toolbar {
            // Passive status readouts stay out of the shared glass capsule;
            // only real actions get the Liquid Glass treatment.
            if account.cacheUnavailable {
                ToolbarItem {
                    Label("No offline cache", systemImage: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(Color.rcStatusWarning)
                        .help("The local message cache could not be opened; "
                            + "this session won't persist history between launches.")
                }
                .sharedBackgroundVisibility(.hidden)
            }
            ToolbarItem {
                SyncStateBadge(state: model.syncState)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button {
                    showGlobalSearch = true
                } label: {
                    Label("Go to…", systemImage: "square.grid.2x2")
                }
                .keyboardShortcut("k", modifiers: .command)
                .help("Search channels and people (⌘K)")
            }
        }
        .sheet(isPresented: $showGlobalSearch) {
            GlobalSearchSheet(joinedRooms: model.rooms) { roomId in
                account.selectedRoomId = roomId
            }
        }
        .navigationTitle(account.displayName)
    }
}

@MainActor
@Observable
final class RoomListModel {
    private(set) var rooms: [RoomSummary] = []
    private(set) var syncState: SyncState = .idle
    /// DM partners' presence, keyed by user id.
    private(set) var presence: [String: UserPresence] = [:]

    func observe(_ client: RocketChatClient) async {
        async let stateTask: Void = {
            for await state in await client.syncStateUpdates() {
                await MainActor.run { self.syncState = state }
            }
        }()
        async let presenceTask: Void = {
            for await map in await client.presenceUpdates() {
                await MainActor.run { self.presence = map }
            }
        }()
        for await list in await client.roomListUpdates() {
            self.rooms = list.filter(\.open)
            // Tracking is additive in the SDK; new DMs just add their peer.
            let peers = rooms.compactMap(\.directPeerId)
            if !peers.isEmpty {
                await client.trackPresence(userIds: peers)
            }
        }
        await stateTask
        await presenceTask
    }
}

struct SidebarView: View {
    @Environment(AppSession.self) private var session
    let rooms: [RoomSummary]
    let presence: [String: UserPresence]
    @Binding var selection: String?

    private var channels: [RoomSummary] {
        rooms.filter { $0.type == .channel || $0.type == .privateGroup }
    }

    private var directMessages: [RoomSummary] {
        rooms.filter { $0.type == .directMessage }
    }

    var body: some View {
        List(selection: $selection) {
            if !channels.isEmpty {
                Section("Channels") {
                    ForEach(channels) { room in
                        row(room)
                    }
                }
            }
            if !directMessages.isEmpty {
                Section("Direct Messages") {
                    ForEach(directMessages) { room in
                        row(room)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ room: RoomSummary) -> some View {
        RoomRow(room: room, presence: room.directPeerId.flatMap { presence[$0] })
            .tag(room.id)
            .contextMenu {
                if room.unread > 0 || room.alert {
                    Button("Mark as Read") {
                        Task { try? await session.client?.markRead(roomId: room.id) }
                    }
                } else {
                    Button("Mark as Unread") {
                        Task { try? await session.client?.markUnread(roomId: room.id) }
                    }
                }
            }
    }
}

struct RoomRow: View {
    let room: RoomSummary
    /// The DM partner's status; nil for channels or when unknown.
    var presence: UserPresence?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: room.type == .directMessage
                ? "person.circle"
                : room.type == .privateGroup ? "lock" : "number")
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .overlay(alignment: .bottomTrailing) {
                    if let presence {
                        PresenceDot(status: presence.status)
                            .offset(x: 2, y: 2)
                    }
                }
                .help(presence.map(PresenceDot.helpText) ?? "")
            Text(room.displayName)
                .font(.rcBody)
                .fontWeight(room.unread > 0 || room.alert ? .semibold : .regular)
                .lineLimit(1)
            Spacer()
            // Fuselage unread variants: user mention > unread thread >
            // group mention (@all/@here) > plain unread.
            if room.mentions > 0 {
                badge("@\(room.mentions)", color: .rcBadgeMention)
            } else if room.unreadThreads > 0 {
                badge("\(room.unreadThreads)", color: .rcBadgeThread)
            } else if room.groupMentions > 0 {
                badge("@\(room.groupMentions)", color: .rcBadgeGroupMention)
            } else if room.unread > 0 {
                badge("\(room.unread)", color: .rcBadgePlain)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color)
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }
}

/// Fuselage-style status bullet, ringed so it reads on any row background.
struct PresenceDot: View {
    let status: PresenceStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay(Circle().stroke(Color.rcSurfaceLight, lineWidth: 1.5))
            .accessibilityLabel(Self.label(status))
    }

    private var color: Color {
        switch status {
        case .online: .rcPresenceOnline
        case .away: .rcPresenceAway
        case .busy: .rcPresenceBusy
        case .offline, .unknown: .rcPresenceOffline
        }
    }

    static func label(_ status: PresenceStatus) -> String {
        switch status {
        case .online: "Online"
        case .away: "Away"
        case .busy: "Busy"
        case .offline: "Offline"
        case .unknown: "Status unknown"
        }
    }

    static func helpText(_ presence: UserPresence) -> String {
        let text = presence.statusText?.trimmingCharacters(in: .whitespaces) ?? ""
        return text.isEmpty ? label(presence.status) : "\(label(presence.status)) — \(text)"
    }
}

struct SyncStateBadge: View {
    let state: SyncState

    var body: some View {
        switch state {
        case .degraded:
            Label("Reconnecting…", systemImage: "wifi.exclamationmark")
                .foregroundStyle(Color.rcStatusWarning)
        case .unauthorized:
            Label("Session expired", systemImage: "lock.slash")
                .foregroundStyle(Color.rcDanger)
        case .syncing:
            ProgressView().controlSize(.small)
        case .synced, .idle:
            EmptyView()
        }
    }
}
