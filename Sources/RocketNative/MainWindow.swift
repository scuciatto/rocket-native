import SwiftUI
import RocketChatSDK

struct MainWindow: View {
    @Environment(AppSession.self) private var session
    @State private var model = RoomListModel()
    @State private var selectedRoomId: String?
    @State private var showGlobalSearch = false

    var body: some View {
        NavigationSplitView {
            SidebarView(rooms: model.rooms, selection: $selectedRoomId)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let roomId = selectedRoomId,
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
            guard let client = session.client else { return }
            await model.observe(client)
        }
        .toolbar {
            if session.cacheUnavailable {
                Label("No offline cache", systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.orange)
                    .help("The local message cache could not be opened; "
                        + "this session won't persist history between launches.")
            }
            SyncStateBadge(state: model.syncState)
            Button {
                showGlobalSearch = true
            } label: {
                Label("Go to…", systemImage: "square.grid.2x2")
            }
            .keyboardShortcut("k", modifiers: .command)
            .help("Search channels and people (⌘K)")
        }
        .sheet(isPresented: $showGlobalSearch) {
            GlobalSearchSheet(joinedRooms: model.rooms) { roomId in
                selectedRoomId = roomId
            }
        }
    }
}

@MainActor
@Observable
final class RoomListModel {
    private(set) var rooms: [RoomSummary] = []
    private(set) var syncState: SyncState = .idle

    func observe(_ client: RocketChatClient) async {
        async let stateTask: Void = {
            for await state in await client.syncStateUpdates() {
                await MainActor.run { self.syncState = state }
            }
        }()
        for await list in await client.roomListUpdates() {
            self.rooms = list.filter(\.open)
        }
        await stateTask
    }
}

struct SidebarView: View {
    let rooms: [RoomSummary]
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
                        RoomRow(room: room).tag(room.id)
                    }
                }
            }
            if !directMessages.isEmpty {
                Section("Direct Messages") {
                    ForEach(directMessages) { room in
                        RoomRow(room: room).tag(room.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct RoomRow: View {
    let room: RoomSummary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: room.type == .directMessage
                ? "person.circle"
                : room.type == .privateGroup ? "lock" : "number")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(room.displayName)
                .fontWeight(room.unread > 0 || room.alert ? .semibold : .regular)
                .lineLimit(1)
            Spacer()
            if room.mentions > 0 {
                badge("@\(room.mentions)", prominent: true)
            } else if room.unread > 0 {
                badge("\(room.unread)", prominent: false)
            }
        }
    }

    private func badge(_ text: String, prominent: Bool) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(prominent ? Color.red : Color.secondary.opacity(0.35))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }
}

struct SyncStateBadge: View {
    let state: SyncState

    var body: some View {
        switch state {
        case .degraded:
            Label("Reconnecting…", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.orange)
        case .unauthorized:
            Label("Session expired", systemImage: "lock.slash")
                .foregroundStyle(.red)
        case .syncing:
            ProgressView().controlSize(.small)
        case .synced, .idle:
            EmptyView()
        }
    }
}
