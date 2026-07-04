import SwiftUI
import RocketChatSDK

/// Thread view shown in the trailing inspector: parent message on top,
/// live replies below, its own composer.
struct ThreadPanel: View {
    @Environment(AppSession.self) private var session
    let parent: Message
    let roomId: String
    let onClose: () -> Void

    @State private var model = ThreadModel()
    @State private var draft = ""
    @State private var editingMessage: Message?
    @State private var deleteCandidate: Message?

    private var actions: MessageActions {
        MessageActions(
            openThread: nil,
            react: { message, emoji in
                Task { await model.react(message: message, emoji: emoji) }
            },
            edit: { message in
                editingMessage = message
                draft = message.msg
            },
            delete: { deleteCandidate = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Thread")
                    .font(.headline)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    MessageRow(
                        entry: TimelineEntry(message: parent, delivery: .sent),
                        isGrouped: false,
                        actions: actions)
                    Divider().padding(.vertical, 6)
                    ForEach(model.entries) { entry in
                        MessageRow(entry: entry, isGrouped: false, actions: actions)
                    }
                }
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)

            Divider()
            if let editing = editingMessage {
                EditingBanner(message: editing) {
                    editingMessage = nil
                    draft = ""
                }
            }
            ComposerBar(draft: $draft, roomName: "thread") {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                draft = ""
                if let editing = editingMessage {
                    editingMessage = nil
                    await model.edit(messageId: editing._id, text: text)
                } else {
                    await model.send(text)
                }
            }
        }
        .confirmationDialog(
            "Delete this message?",
            isPresented: .init(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }),
            presenting: deleteCandidate
        ) { message in
            Button("Delete", role: .destructive) {
                deleteCandidate = nil
                Task { await model.delete(messageId: message._id) }
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: { message in
            Text("“\(message.msg.prefix(80))” will be deleted for everyone.")
        }
        .task(id: parent._id) {
            guard let client = session.client else { return }
            await model.open(threadId: parent._id, roomId: roomId, client: client)
        }
        .onDisappear {
            model.close()
        }
    }
}

@MainActor
@Observable
final class ThreadModel {
    private(set) var entries: [TimelineEntry] = []

    private var handle: ThreadHandle?
    private var observation: Task<Void, Never>?

    func open(threadId: String, roomId: String, client: RocketChatClient) async {
        close()
        guard let handle = try? await client.openThread(threadId, in: roomId) else { return }
        self.handle = handle
        observation = Task {
            for await snapshot in await handle.timelineUpdates() {
                self.entries = snapshot.entries
            }
        }
        await observation?.value
    }

    func send(_ text: String) async {
        try? await handle?.send(text: text)
    }

    func react(message: Message, emoji: String) async {
        try? await handle?.react(messageId: message._id, emoji: emoji)
    }

    func edit(messageId: String, text: String) async {
        try? await handle?.edit(messageId: messageId, text: text)
    }

    func delete(messageId: String) async {
        try? await handle?.delete(messageId: messageId)
    }

    func close() {
        observation?.cancel()
        observation = nil
        let handle = handle
        Task { await handle?.close() }
        self.handle = nil
        entries = []
    }
}
