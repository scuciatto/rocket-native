import SwiftUI
import RocketChatSDK

/// One room's timeline + composer. Owns the SDK `RoomHandle` for its
/// lifetime: opened on appear, closed on disappear.
/// Per-message affordances a timeline offers; rows only get what their
/// container wires up (e.g. thread panels don't offer "Reply in Thread").
struct MessageActions {
    var openThread: ((Message) -> Void)?
    var react: ((Message, String) -> Void)?
    var edit: ((Message) -> Void)?
    var delete: ((Message) -> Void)?

    /// Reaction palette for the context menu, shortcode → glyph.
    static let quickReactions: [(code: String, glyph: String)] = [
        ("thumbsup", "👍"), ("heart", "❤️"), ("joy", "😂"),
        ("tada", "🎉"), ("eyes", "👀"), ("white_check_mark", "✅"),
    ]
}

struct RoomView: View {
    @Environment(AppSession.self) private var session
    let room: RoomSummary
    @State private var model = TimelineModel()
    @State private var draft = ""
    @State private var activeThread: Message?
    @State private var showSearch = false
    @State private var editingMessage: Message?
    @State private var deleteCandidate: Message?

    var body: some View {
        VStack(spacing: 0) {
            TimelineList(
                entries: model.entries,
                loadOlder: { await model.loadOlder() },
                actions: MessageActions(
                    openThread: { activeThread = $0 },
                    react: { message, emoji in
                        Task { await model.react(message: message, emoji: emoji) }
                    },
                    edit: { message in
                        editingMessage = message
                        draft = message.msg
                    },
                    delete: { deleteCandidate = $0 }))
            Divider()
            if let editing = editingMessage {
                EditingBanner(message: editing) {
                    editingMessage = nil
                    draft = ""
                }
            }
            ComposerBar(draft: $draft, roomName: room.displayName) {
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
        .navigationTitle(room.displayName)
        .navigationSubtitle(room.topic ?? "")
        .toolbar {
            ToolbarItem {
                Button {
                    showSearch = true
                } label: {
                    Label("Search in Room", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
        .inspector(isPresented: .init(
            get: { activeThread != nil },
            set: { if !$0 { activeThread = nil } }
        )) {
            if let parent = activeThread {
                ThreadPanel(parent: parent, roomId: room.id) {
                    activeThread = nil
                }
                .inspectorColumnWidth(min: 280, ideal: 340)
            }
        }
        .sheet(isPresented: $showSearch) {
            RoomSearchSheet(room: room) { parent in
                showSearch = false
                activeThread = parent
            }
        }
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

    func react(message: Message, emoji: String) async {
        try? await handle?.react(messageId: message._id, emoji: emoji)
    }

    func edit(messageId: String, text: String) async {
        do {
            try await handle?.edit(messageId: messageId, text: text)
        } catch {
            sendError = "Edit failed."
        }
    }

    func delete(messageId: String) async {
        do {
            try await handle?.delete(messageId: messageId)
        } catch {
            sendError = "Delete failed."
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
    var actions: MessageActions?

    /// Thread replies (tmid set, not echoed to main) live in the thread panel.
    private var mainEntries: [TimelineEntry] {
        entries.filter { $0.message.tmid == nil }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Button("Load earlier messages") {
                    Task { await loadOlder() }
                }
                .buttonStyle(.link)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                let visible = mainEntries
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                    MessageRow(
                        entry: entry,
                        isGrouped: isGrouped(visible, at: index),
                        actions: actions)
                }
            }
            .padding(.bottom, 8)
        }
        .defaultScrollAnchor(.bottom)
    }

    /// Consecutive messages from the same author within 5 minutes share one header.
    private func isGrouped(_ list: [TimelineEntry], at index: Int) -> Bool {
        guard index > 0 else { return false }
        let current = list[index].message
        let previous = list[index - 1].message
        return current.u._id == previous.u._id
            && current.t == nil && previous.t == nil
            && current.ts.timeIntervalSince(previous.ts) < 300
    }
}

struct MessageRow: View {
    @Environment(AppSession.self) private var session
    let entry: TimelineEntry
    let isGrouped: Bool
    var actions: MessageActions?

    private var message: Message { entry.message }

    private var isOwnMessage: Bool {
        session.profile?._id == message.u._id
    }

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
        HStack(alignment: .top, spacing: 10) {
            if isGrouped {
                Color.clear.frame(width: 28)
            } else if let username = message.u.username {
                AvatarView(username: username)
                    .padding(.top, 8)
            }
            VStack(alignment: .leading, spacing: 3) {
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
                messageBody
                attachmentViews
                reactionsRow
                threadIndicator
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .contextMenu {
            if let react = actions?.react, entry.delivery == .sent {
                ForEach(MessageActions.quickReactions, id: \.code) { reaction in
                    Button("\(reaction.glyph) :\(reaction.code):") {
                        react(message, ":\(reaction.code):")
                    }
                }
                Divider()
            }
            if let openThread = actions?.openThread {
                Button("Reply in Thread") { openThread(message) }
            }
            if isOwnMessage, entry.delivery != .sending {
                if let edit = actions?.edit {
                    Button("Edit Message") { edit(message) }
                }
                if let delete = actions?.delete {
                    Button("Delete Message…", role: .destructive) { delete(message) }
                }
            }
        }
    }

    @ViewBuilder
    private var threadIndicator: some View {
        if let count = message.tcount, count > 0, let openThread = actions?.openThread {
            Button {
                openThread(message)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text("\(count) \(count == 1 ? "reply" : "replies")")
                    if let last = message.tlm {
                        Text(last, style: .relative)
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
            }
            .buttonStyle(.link)
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var messageBody: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let blocks = MarkdownRenderer.blocks(from: message.md) {
                RenderedBlocksView(blocks: blocks)
                    .opacity(entry.delivery == .sending ? 0.5 : 1)
            } else if !message.msg.isEmpty {
                Text(message.msg)
                    .textSelection(.enabled)
                    .opacity(entry.delivery == .sending ? 0.5 : 1)
            }
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

    @ViewBuilder
    private var attachmentViews: some View {
        ForEach(Array((message.attachments ?? []).enumerated()), id: \.offset) { _, attachment in
            AttachmentView(attachment: attachment)
        }
    }

    @ViewBuilder
    private var reactionsRow: some View {
        if let reactions = message.reactions, !reactions.isEmpty {
            HStack(spacing: 4) {
                ForEach(reactions.sorted(by: { $0.key < $1.key }), id: \.key) { emoji, reaction in
                    let mine = reaction.usernames.contains(session.profile?.username ?? "")
                    Button {
                        actions?.react?(message, emoji)
                    } label: {
                        HStack(spacing: 3) {
                            Text(EmojiMap.unicode(forShortCode: emoji) ?? emoji)
                            Text("\(reaction.usernames.count)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(mine ? Color.accentColor : .secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(mine
                            ? Color.accentColor.opacity(0.18)
                            : Color.secondary.opacity(0.12))
                        .overlay {
                            if mine {
                                Capsule().strokeBorder(
                                    Color.accentColor.opacity(0.5), lineWidth: 1)
                            }
                        }
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(actions?.react == nil)
                    .help(reaction.usernames.joined(separator: ", "))
                }
            }
            .padding(.top, 2)
        }
    }
}

/// Shown above the composer while editing; Esc or the button cancels.
struct EditingBanner: View {
    let message: Message
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
            Text("Editing message")
                .fontWeight(.medium)
            Text(message.msg)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }
}

struct RenderedBlocksView: View {
    let blocks: [MarkdownRenderer.Block]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownRenderer.Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(text).textSelection(.enabled)
        case .heading(let level, let text):
            Text(text)
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .textSelection(.enabled)
        case .code(_, let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case .quote(let paragraphs):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, text in
                        Text(text).textSelection(.enabled)
                    }
                }
                .foregroundStyle(.secondary)
            }
        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .foregroundStyle(.secondary)
                        Text(item).textSelection(.enabled)
                    }
                }
            }
        }
    }
}

struct AvatarView: View {
    @Environment(AppSession.self) private var session
    let username: String

    var body: some View {
        AsyncImage(url: session.client?.avatarURL(username: username, size: 56)) { image in
            image.resizable()
        } placeholder: {
            Circle().fill(Color.secondary.opacity(0.25))
                .overlay {
                    Text(String(username.prefix(1)).uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct AttachmentView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openURL) private var openURL
    let attachment: Attachment

    var body: some View {
        if let imagePath = attachment.imageURL {
            AsyncImage(url: resolved(imagePath)) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.1))
                    .overlay { ProgressView().controlSize(.small) }
                    .frame(height: 120)
            }
            .frame(maxWidth: 360, maxHeight: 280, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if let title = attachment.title {
            Button {
                if let path = attachment.titleLink, let url = resolved(path) {
                    openURL(url)
                }
            } label: {
                Label(title, systemImage: "doc")
                    .font(.callout)
            }
            .buttonStyle(.link)
        } else if let text = attachment.text {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: 3)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
    }

    private func resolved(_ path: String) -> URL? {
        if path.hasPrefix("http") { return URL(string: path) }
        return session.fileURL(path: path)
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
