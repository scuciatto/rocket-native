import SwiftUI
import RocketChatSDK

/// In-room message search (⌘F): full-text via `chat.search`.
struct RoomSearchSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let room: RoomSummary
    /// Called with the tapped result so the caller can jump the timeline to
    /// it (or open its thread when the hit is a thread reply).
    let onSelect: (Message) -> Void

    @State private var query = ""
    @State private var results: [Message] = []
    @State private var searched = false
    @State private var searching = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search in \(room.displayName)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit { search() }
                if searching {
                    ProgressView().controlSize(.small)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()

            if results.isEmpty {
                ContentUnavailableView(
                    searched ? "No Results" : "Search Messages",
                    systemImage: "text.magnifyingglass",
                    description: Text(searched
                        ? "No messages match “\(query)”."
                        : "Type a query and press Return."))
                    .frame(maxHeight: .infinity)
            } else {
                List(results) { message in
                    Button {
                        onSelect(message)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(message.u.username ?? "?")
                                    .font(.rcSenderName)
                                    .foregroundStyle(Color.rcFontTitlesLabels)
                                Text(message.ts, format: .dateTime.day().month().hour().minute())
                                    .font(.rcTimestamp)
                                    .foregroundStyle(Color.rcFontAnnotation)
                            }
                            Text(message.msg)
                                .font(.rcBody)
                                .lineLimit(3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 520, height: 420)
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let client = session.client else { return }
        searching = true
        Task {
            defer { searching = false }
            results = (try? await client.searchMessages(
                in: room.id, text: text, count: 50)) ?? []
            searched = true
        }
    }
}

/// Global search (⌘K): spotlight across users and channels, joined rooms
/// first. Selecting a channel joins it if needed; selecting a user opens a DM.
struct GlobalSearchSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let joinedRooms: [RoomSummary]
    let onOpenRoom: (String) -> Void

    @State private var query = ""
    @State private var spotlight: SpotlightResult?
    @State private var searchTask: Task<Void, Never>?
    @State private var actionError: String?

    private var joinedMatches: [RoomSummary] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return [] }
        return joinedRooms.filter {
            $0.displayName.lowercased().contains(text.dropFirst(text.hasPrefix("#") ? 1 : 0))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search channels and people…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()

            List {
                if !joinedMatches.isEmpty {
                    Section("Joined") {
                        ForEach(joinedMatches) { room in
                            resultRow(
                                icon: room.type == .directMessage ? "person.circle" : "number",
                                title: room.displayName, subtitle: room.topic
                            ) {
                                onOpenRoom(room.id)
                                dismiss()
                            }
                        }
                    }
                }
                if let users = spotlight?.users, !users.isEmpty {
                    Section("People") {
                        ForEach(users) { user in
                            resultRow(
                                icon: "person.circle",
                                title: user.name ?? user.username ?? "?",
                                subtitle: user.username.map { "@\($0)" }
                            ) {
                                openDM(user)
                            }
                        }
                    }
                }
                if let rooms = spotlight?.rooms, !rooms.isEmpty {
                    Section("Channels to Join") {
                        ForEach(rooms) { room in
                            resultRow(
                                icon: "number.circle",
                                title: room.fname ?? room.name ?? room._id,
                                subtitle: room.topic
                            ) {
                                join(room)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)

            if let actionError {
                Text(actionError)
                    .font(.callout)
                    .foregroundStyle(Color.rcDanger)
                    .padding(8)
            }
        }
        .frame(width: 520, height: 440)
        .onChange(of: query) { _, text in
            searchTask?.cancel()
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2, let client = session.client else {
                spotlight = nil
                return
            }
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(250))   // debounce
                guard !Task.isCancelled else { return }
                spotlight = try? await client.spotlight(trimmed)
            }
        }
    }

    private func resultRow(
        icon: String, title: String, subtitle: String?, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.rcBody)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.rcCaption)
                            .foregroundStyle(Color.rcFontSecondaryInfo)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openDM(_ user: SpotlightResult.User) {
        guard let client = session.client, let username = user.username else { return }
        Task {
            do {
                let room = try await client.createDirectMessage(username: username)
                onOpenRoom(room._id)
                dismiss()
            } catch {
                actionError = "Could not open a conversation with @\(username)."
            }
        }
    }

    private func join(_ room: Room) {
        guard let client = session.client else { return }
        Task {
            do {
                let joined = try await client.joinChannel(roomId: room._id)
                onOpenRoom(joined._id)
                dismiss()
            } catch {
                actionError = "Could not join #\(room.name ?? room._id)."
            }
        }
    }
}
