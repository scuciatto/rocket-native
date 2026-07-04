import Foundation

public struct Message: Codable, Sendable, Identifiable, Equatable {
    public var id: String { _id }
    public let _id: String
    public var rid: String
    /// Raw message text. Prefer rendering `md` when present.
    public var msg: String
    public var ts: Date
    public var u: MiniUser
    public var _updatedAt: Date?
    public var editedAt: Date?
    public var editedBy: MiniUser?
    /// System-message type (`uj` user joined, `rm` removed, …); nil for user messages.
    public var t: String?
    public var attachments: [Attachment]?
    public var reactions: [String: Reaction]?
    /// Server-parsed markdown AST (message-parser tokens). Version-drifting,
    /// so kept dynamic; the renderer walks it leniently.
    public var md: JSONValue?

    // Threads
    /// Parent message id when this message is a thread reply.
    public var tmid: String?
    /// Reply count when this message is a thread parent.
    public var tcount: Int?
    /// Last thread activity when this message is a thread parent.
    public var tlm: Date?
    public var replies: [String]?

    public var pinned: Bool?
    public var starred: JSONValue?
    public var urls: [JSONValue]?

    public struct Reaction: Codable, Sendable, Equatable {
        public var usernames: [String]
        public var names: [String?]?
    }
}

public struct Attachment: Codable, Sendable, Equatable {
    public var title: String?
    public var text: String?
    public var color: String?
    public var authorName: String?
    public var imageURL: String?
    public var audioURL: String?
    public var videoURL: String?
    public var titleLink: String?
    public var messageLink: String?
    public var description: String?

    enum CodingKeys: String, CodingKey {
        case title, text, color, description
        case authorName = "author_name"
        case imageURL = "image_url"
        case audioURL = "audio_url"
        case videoURL = "video_url"
        case titleLink = "title_link"
        case messageLink = "message_link"
    }
}

/// Tombstone from `chat.syncMessages`' `deleted` array.
public struct DeletedMessage: Codable, Sendable, Equatable {
    public let _id: String
    public var _deletedAt: Date?
}

/// One `chat.syncMessages` delta: inserts + edits, and deletions.
public struct MessageDelta: Sendable {
    public var updated: [Message]
    public var deleted: [DeletedMessage]
}

/// Client-side message ids, Meteor `Random.id()` style: the server accepts
/// them on `chat.sendMessage`, which is what makes optimistic sends
/// reconcile instead of duplicating.
enum MessageID {
    private static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTWXYZabcdefghijkmnopqrstuvwxyz")

    static func generate() -> String {
        String((0..<17).map { _ in alphabet.randomElement()! })
    }
}
