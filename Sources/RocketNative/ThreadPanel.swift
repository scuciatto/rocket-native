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
                        isGrouped: false)
                    Divider().padding(.vertical, 6)
                    ForEach(model.entries) { entry in
                        MessageRow(entry: entry, isGrouped: false)
                    }
                }
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)

            Divider()
            ComposerBar(draft: $draft, roomName: "thread") {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                draft = ""
                await model.send(text)
            }
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

    func close() {
        observation?.cancel()
        observation = nil
        let handle = handle
        Task { await handle?.close() }
        self.handle = nil
        entries = []
    }
}
