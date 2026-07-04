import SwiftUI
import RocketChatSDK

/// One room's timeline + composer. Owns the SDK `RoomHandle` for its
/// lifetime: opened on appear, closed on disappear.
struct RoomView: View {
    @Environment(AppSession.self) private var session
    let room: RoomSummary
    @State private var model = TimelineModel()
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            TimelineList(entries: model.entries, loadOlder: {
                await model.loadOlder()
            })
            Divider()
            ComposerBar(draft: $draft, roomName: room.displayName) {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                draft = ""
                await model.send(text)
            }
        }
        .navigationTitle(room.displayName)
        .navigationSubtitle(room.topic ?? "")
        .task {
            guard let client = session.client else { return }
            await model.open(roomId: room.id, client: client)
        }
        .onDisappear {
            model.close()
        }
    }
}

@MainActor
@Observable
final class TimelineModel {
    private(set) var entries: [TimelineEntry] = []
    var sendError: String?

    private var handle: RoomHandle?
    private var observation: Task<Void, Never>?

    func open(roomId: String, client: RocketChatClient) async {
        do {
            let handle = try await client.openRoom(roomId)
            self.handle = handle
            try? await handle.markRead()
            observation = Task {
                for await snapshot in await handle.timelineUpdates() {
                    self.entries = snapshot.entries
                }
            }
            await observation?.value
        } catch {
            sendError = "Could not load messages."
        }
    }

    func send(_ text: String) async {
        guard let handle else { return }
        do {
            try await handle.send(text: text)
            try? await handle.markRead()
        } catch {
            sendError = "Message failed to send."
        }
    }

    func loadOlder() async {
        try? await handle?.loadOlder()
    }

    func close() {
        observation?.cancel()
        let handle = handle
        Task { await handle?.close() }
        self.handle = nil
    }
}

struct TimelineList: View {
    let entries: [TimelineEntry]
    let loadOlder: () async -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Button("Load earlier messages") {
                    Task { await loadOlder() }
                }
                .buttonStyle(.link)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    MessageRow(
                        entry: entry,
                        isGrouped: isGrouped(at: index))
                }
            }
            .padding(.bottom, 8)
        }
        .defaultScrollAnchor(.bottom)
    }

    /// Consecutive messages from the same author within 5 minutes share one header.
    private func isGrouped(at index: Int) -> Bool {
        guard index > 0 else { return false }
        let current = entries[index].message
        let previous = entries[index - 1].message
        return current.u._id == previous.u._id
            && current.t == nil && previous.t == nil
            && current.ts.timeIntervalSince(previous.ts) < 300
    }
}

struct MessageRow: View {
    let entry: TimelineEntry
    let isGrouped: Bool

    private var message: Message { entry.message }

    var body: some View {
        if message.t != nil {
            systemRow
        } else {
            userRow
        }
    }

    private var systemRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
            Text("\(message.u.username ?? "?") \(systemDescription)")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var systemDescription: String {
        switch message.t {
        case "uj": "joined the channel"
        case "ul", "ru": "left the channel"
        case "au": "was added"
        case "rm": "removed a message"
        default: message.msg.isEmpty ? (message.t ?? "") : message.msg
        }
    }

    private var userRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !isGrouped {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message.u.name ?? message.u.username ?? "?")
                        .fontWeight(.semibold)
                    Text(message.ts, style: .time)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 8)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(message.msg)
                    .textSelection(.enabled)
                    .opacity(entry.delivery == .sending ? 0.5 : 1)
                if entry.delivery == .failed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .help("Failed to send")
                }
                if message.editedAt != nil {
                    Text("(edited)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ComposerBar: View {
    @Binding var draft: String
    let roomName: String
    let onSend: () async -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Message \(roomName)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .onSubmit {
                    Task { await onSend() }
                }
            Button {
                Task { await onSend() }
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderless)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(10)
        .background(.bar)
    }
}
