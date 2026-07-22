import SwiftUI
import UniformTypeIdentifiers
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
                unreadAnchor: model.unreadAnchor,
                selfUserId: session.profile?._id,
                highlightedId: model.highlightedMessageId,
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
            if !model.uploadingNames.isEmpty {
                UploadingBanner(names: model.uploadingNames)
            }
            if let uploadError = model.uploadError {
                Text(uploadError)
                    .font(.callout)
                    .foregroundStyle(Color.rcDanger)
                    .padding(.vertical, 4)
            }
            if let jumpError = model.jumpError {
                Text(jumpError)
                    .font(.callout)
                    .foregroundStyle(Color.rcDanger)
                    .padding(.vertical, 4)
            }
            if let editing = editingMessage {
                EditingBanner(message: editing) {
                    editingMessage = nil
                    draft = ""
                }
            }
            ComposerBar(
                draft: $draft, roomName: room.displayName,
                onSend: {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    draft = ""
                    if let editing = editingMessage {
                        editingMessage = nil
                        await model.edit(messageId: editing._id, text: text)
                    } else {
                        await model.send(text)
                    }
                },
                onAttach: { urls in
                    Task { await model.upload(urls: urls) }
                })
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.upload(urls: urls) }
            return true
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
            RoomSearchSheet(room: room) { message in
                showSearch = false
                if let threadId = message.tmid {
                    // Thread replies aren't on the main timeline; open
                    // their thread, rooted at the real parent message.
                    openThread(threadId, fallingBackTo: message)
                } else {
                    Task { await model.jump(to: message._id) }
                }
            }
        }
        .task {
            guard let client = session.client else { return }
            await model.open(room: room, client: client)
        }
        .onDisappear {
            model.close()
        }
    }

    private func openThread(_ threadId: String, fallingBackTo message: Message) {
        Task {
            if let client = session.client,
               let parent = try? await client.getMessage(threadId) {
                activeThread = parent
            } else {
                activeThread = message
            }
        }
    }
}

@MainActor
@Observable
final class TimelineModel {
    private(set) var entries: [TimelineEntry] = []
    /// Where the "new messages" divider sits: the last-seen timestamp at the
    /// moment the room was opened (nil when everything was already read).
    private(set) var unreadAnchor: Date?
    var sendError: String?

    private var handle: RoomHandle?
    private var observation: Task<Void, Never>?

    func open(room: RoomSummary, client: RocketChatClient) async {
        // Capture the divider anchor before marking the room read.
        unreadAnchor = room.unread > 0 || room.alert ? room.lastSeen : nil
        do {
            let handle = try await client.openRoom(room.id)
            self.handle = handle
            try? await handle.markRead()
            var lastSeenEntryId: String?
            observation = Task {
                for await snapshot in await handle.timelineUpdates() {
                    self.entries = snapshot.entries
                    // Arrivals while the room is on screen stay read.
                    let newestId = snapshot.entries.last?.id
                    if let newestId, newestId != lastSeenEntryId {
                        let isFirst = lastSeenEntryId == nil
                        lastSeenEntryId = newestId
                        if !isFirst {
                            try? await handle.markRead()
                        }
                    }
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

    // MARK: - Jump to message

    /// Row the timeline should scroll to and flash; auto-clears shortly after.
    private(set) var highlightedMessageId: String?
    var jumpError: String?

    /// Pages history until the message is in the window, then flags it for
    /// scroll-and-highlight (e.g. from a search result).
    func jump(to messageId: String) async {
        guard let handle else { return }
        jumpError = nil
        let found = (try? await handle.loadOlder(until: messageId)) ?? false
        guard found else {
            jumpError = "Couldn't find that message in the loaded history."
            return
        }
        // Refresh entries directly so the target row exists before the view
        // scrolls to it — the observation stream may not have caught up yet.
        entries = await handle.timeline().entries
        highlightedMessageId = messageId
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if highlightedMessageId == messageId {
                highlightedMessageId = nil
            }
        }
    }

    // MARK: - Uploads

    private(set) var uploadingNames: [String] = []
    var uploadError: String?

    func upload(urls: [URL]) async {
        guard let handle else { return }
        uploadError = nil
        for url in urls {
            guard let file = Self.readFile(url) else {
                uploadError = "Could not read “\(url.lastPathComponent)”."
                continue
            }
            guard file.data.count <= 100 * 1024 * 1024 else {
                uploadError = "“\(file.filename)” is larger than 100 MB."
                continue
            }
            uploadingNames.append(file.filename)
            defer { uploadingNames.removeAll { $0 == file.filename } }
            do {
                try await handle.upload(file)
            } catch {
                uploadError = "Upload of “\(file.filename)” failed."
            }
        }
    }

    /// Reads a picked/dropped file, honoring security-scoped access.
    private static func readFile(_ url: URL) -> UploadableFile? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mimeType = UTType(filenameExtension: url.pathExtension)?
            .preferredMIMEType ?? "application/octet-stream"
        return UploadableFile(
            data: data, filename: url.lastPathComponent, mimeType: mimeType)
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
    var unreadAnchor: Date?
    var selfUserId: String?
    var highlightedId: String?
    let loadOlder: () async -> Void
    var actions: MessageActions?

    /// Thread replies (tmid set, not echoed to main) live in the thread panel.
    private var mainEntries: [TimelineEntry] {
        entries.filter { $0.message.tmid == nil }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Button("Load earlier messages") {
                        Task { await loadOlder() }
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(Color.rcFontInfo)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)

                    let visible = mainEntries
                    let dividerId = Self.firstUnreadId(
                        entries: visible, anchor: unreadAnchor, selfUserId: selfUserId)
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                        if entry.id == dividerId {
                            UnreadDivider()
                        }
                        MessageRow(
                            entry: entry,
                            isGrouped: isGrouped(visible, at: index),
                            isHighlighted: entry.id == highlightedId,
                            actions: actions)
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .defaultScrollAnchor(.bottom)
            .onChange(of: highlightedId) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
    }

    /// First message someone else sent after the last-seen anchor — where
    /// the "new messages" divider renders. Pure for testability.
    static func firstUnreadId(
        entries: [TimelineEntry], anchor: Date?, selfUserId: String?
    ) -> String? {
        guard let anchor else { return nil }
        return entries.first {
            $0.message.ts > anchor && $0.message.u._id != selfUserId
        }?.id
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
    /// Flashes the row background (jump-to-message landing).
    var isHighlighted = false
    var actions: MessageActions?

    @State private var isHovering = false

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
        .foregroundStyle(Color.rcFontSecondaryInfo)
        .padding(.horizontal, RCSpace.x5)
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
        // Fuselage gutter: 28pt avatar + 8pt gap = 36pt.
        HStack(alignment: .top, spacing: RCSpace.x2) {
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
                            .font(.rcSenderName)
                            .foregroundStyle(Color.rcFontTitlesLabels)
                        Text(message.ts, style: .time)
                            .font(.rcTimestamp)
                            .foregroundStyle(Color.rcFontAnnotation)
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
        .padding(.horizontal, RCSpace.x5)
        .padding(.vertical, 1)
        .background(isHighlighted
            ? Color.rcPrimary.opacity(0.12)
            : isHovering ? Color.rcSurfaceHover : .clear)
        .animation(.easeOut(duration: 0.4), value: isHighlighted)
        .overlay(alignment: .topTrailing) {
            if isHovering, actions != nil, entry.delivery == .sent {
                MessageActionBar(
                    message: message,
                    isOwnMessage: isOwnMessage,
                    actions: actions!)
                    .padding(.trailing, 12)
                    .offset(y: -6)
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
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
                            .foregroundStyle(Color.rcFontAnnotation)
                    }
                }
                .font(.rcCaption)
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
                    .font(.rcBody)
                    .foregroundStyle(Color.rcFontDefault)
                    .textSelection(.enabled)
                    .opacity(entry.delivery == .sending ? 0.5 : 1)
            }
            if entry.delivery == .failed {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.rcDanger)
                    .help("Failed to send")
            }
            if message.editedAt != nil {
                Text("(edited)")
                    .font(.caption2)
                    .foregroundStyle(Color.rcFontAnnotation)
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
                                .foregroundStyle(mine ? Color.rcPrimary : Color.rcFontSecondaryInfo)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(mine
                            ? Color.rcPrimary.opacity(0.12)
                            : Color.rcSurfaceNeutral)
                        .overlay {
                            if mine {
                                Capsule().strokeBorder(
                                    Color.rcStrokeHighlight, lineWidth: 1)
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

/// Floating hover toolbar over a message: quick reactions, more-reactions
/// menu, thread reply, and edit/delete for own messages.
struct MessageActionBar: View {
    let message: Message
    let isOwnMessage: Bool
    let actions: MessageActions

    var body: some View {
        HStack(spacing: 2) {
            if let react = actions.react {
                // Two most-used reactions inline, the rest behind a menu.
                ForEach(MessageActions.quickReactions.prefix(2), id: \.code) { reaction in
                    barButton(help: ":\(reaction.code):") {
                        react(message, ":\(reaction.code):")
                    } label: {
                        Text(reaction.glyph).font(.system(size: 13))
                    }
                }
                Menu {
                    ForEach(MessageActions.quickReactions, id: \.code) { reaction in
                        Button("\(reaction.glyph) :\(reaction.code):") {
                            react(message, ":\(reaction.code):")
                        }
                    }
                } label: {
                    Image(systemName: "face.smiling")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26, height: 24)
                .help("Add reaction")
            }
            if let openThread = actions.openThread {
                barButton(help: "Reply in thread") {
                    openThread(message)
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
            }
            if isOwnMessage {
                if let edit = actions.edit {
                    barButton(help: "Edit message") {
                        edit(message)
                    } label: {
                        Image(systemName: "pencil")
                    }
                }
                if let delete = actions.delete {
                    barButton(help: "Delete message") {
                        delete(message)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private func barButton(
        help: String, action: @escaping () -> Void,
        @ViewBuilder label: () -> some View
    ) -> some View {
        Button(action: action, label: label)
            .buttonStyle(.borderless)
            .frame(width: 26, height: 24)
            .contentShape(Rectangle())
            .help(help)
    }
}

/// Red "New" separator marking the first unread message.
struct UnreadDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.rcDanger).frame(height: 1)
            Text("New")
                .font(.rcCaptionBold)
                .foregroundStyle(Color.rcDanger)
            Rectangle().fill(Color.rcDanger).frame(height: 1)
        }
        .padding(.horizontal, RCSpace.x5)
        .padding(.vertical, 6)
    }
}

/// Shown above the composer while files are in flight.
struct UploadingBanner: View {
    let names: [String]

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Uploading \(names.joined(separator: ", "))…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.rcSurfaceTint)
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
        .background(Color.rcSurfaceTint)
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
                    .font(.rcMono)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color.rcSurfaceNeutral)
            .clipShape(RoundedRectangle(cornerRadius: RCRadius.medium))
        case .quote(let paragraphs):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: RCRadius.small)
                    .fill(Color.rcStrokeLight)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, text in
                        Text(text).textSelection(.enabled)
                    }
                }
                .foregroundStyle(Color.rcFontSecondaryInfo)
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
            Circle().fill(Color.rcSurfaceNeutral)
                .overlay {
                    Text(String(username.prefix(1)).uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.rcFontSecondaryInfo)
                }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: RCRadius.medium))
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
                    .fill(Color.rcSurfaceTint)
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
                RoundedRectangle(cornerRadius: RCRadius.small)
                    .fill(Color.rcStrokeLight)
                    .frame(width: 3)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(Color.rcFontSecondaryInfo)
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
    /// When set, shows a paperclip button and enables file attach.
    var onAttach: (([URL]) -> Void)?

    @State private var showFilePicker = false
    @State private var showPreview = false
    @FocusState private var isFocused: Bool

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            formattingToolbar
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)

            if showPreview, hasDraft {
                previewPane
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }

            TextField("Message \(roomName)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.rcBody)
                .lineLimit(1...10)
                .frame(minHeight: 44, alignment: .topLeading)
                .padding(.horizontal, 12)
                .focused($isFocused)
                .onSubmit {
                    Task { await onSend() }
                }

            HStack(spacing: 8) {
                if onAttach != nil {
                    ComposerToolButton(
                        icon: "paperclip", help: "Attach a file…"
                    ) {
                        showFilePicker = true
                    }
                }
                Spacer()
                sendButton
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: RCRadius.large)
                .fill(Color.rcSurfaceLight))
        .background(
            // Fuselage focus shadow: a soft halo just outside the card edge.
            RoundedRectangle(cornerRadius: RCRadius.large)
                .stroke(Color.rcShadowHighlight, lineWidth: 4)
                .opacity(isFocused ? 1 : 0))
        .overlay(
            RoundedRectangle(cornerRadius: RCRadius.large)
                .strokeBorder(
                    isFocused ? Color.rcStrokeHighlight : Color.rcStrokeLight,
                    lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(.bar)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                onAttach?(urls)
            }
        }
    }

    /// The small always-visible formatting toolbar across the card's top.
    private var formattingToolbar: some View {
        HStack(spacing: 3) {
            formatButton(.bold)
                .keyboardShortcut("b", modifiers: .command)
            formatButton(.italic)
                .keyboardShortcut("i", modifiers: .command)
            formatButton(.strike)
                .keyboardShortcut("x", modifiers: [.command, .shift])

            toolbarDivider

            formatButton(.inlineCode)
                .keyboardShortcut("c", modifiers: [.command, .shift])
            ComposerToolButton(icon: "curlybraces", help: "Code block (⌘⌥⇧C)") {
                ComposerMarkdown.insertCodeFence(fallback: $draft)
            }
            .keyboardShortcut("c", modifiers: [.command, .option, .shift])

            Spacer()

            ComposerToolButton(
                icon: showPreview ? "eye.fill" : "eye",
                help: "Preview formatting (⌘⇧P)",
                isActive: showPreview
            ) {
                showPreview.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color.rcStrokeExtraLight)
            .frame(width: 1, height: 12)
            .padding(.horizontal, 3)
    }

    private func formatButton(_ style: ComposerMarkdown.Style) -> some View {
        ComposerToolButton(icon: style.icon, help: style.help) {
            ComposerMarkdown.toggle(style, fallback: $draft)
        }
    }

    private var sendButton: some View {
        // The one brand-tinted glass control in the room, per HIG.
        Button {
            Task { await onSend() }
        } label: {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.glassProminent)
        .tint(.rcPrimary)
        .controlSize(.small)
        .disabled(!hasDraft)
        .keyboardShortcut(.return, modifiers: [])
        .help("Send")
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PREVIEW")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.rcFontAnnotation)
            ScrollView {
                Text(ComposerMarkdown.preview(of: draft))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: RCRadius.medium)
                .fill(Color.rcSurfaceTint))
    }
}

/// Small hover-highlighting icon button for the composer toolbar.
struct ComposerToolButton: View {
    let icon: String
    let help: String
    var isActive = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isActive ? Color.rcPrimary : Color.rcFontSecondaryInfo)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: RCRadius.medium)
                        .fill(isActive
                            ? Color.rcPrimary.opacity(0.12)
                            : isHovering ? Color.rcSurfaceHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}
