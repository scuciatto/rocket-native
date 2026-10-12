import Foundation

/// A server-defined emoji from `emoji-custom.list`. Its image is served at
/// `/emoji-custom/<name>.<extension>` (see `RocketChatClient.customEmojiURL`).
public struct CustomEmoji: Codable, Sendable, Identifiable, Equatable {
    public var id: String { _id }
    public let _id: String
    /// Canonical shortcode, without colons. Image URLs always use this.
    public var name: String
    /// Alternative shortcodes; messages and reaction keys may use any of them.
    public var aliases: [String] = []
    /// File extension (`png`, `gif`, ...).
    public var `extension`: String
    /// Changes on every re-upload; busts image caches when the name and
    /// extension stay the same.
    public var etag: String? = nil
    public var _updatedAt: Date? = nil

    public init(
        _id: String, name: String, aliases: [String] = [],
        extension: String, etag: String? = nil, _updatedAt: Date? = nil
    ) {
        self._id = _id
        self.name = name
        self.aliases = aliases
        self.extension = `extension`
        self.etag = etag
        self._updatedAt = _updatedAt
    }

    /// Lenient: only `_id`, `name`, and `extension` are required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _id = try c.decode(String.self, forKey: ._id)
        name = try c.decode(String.self, forKey: .name)
        `extension` = try c.decode(String.self, forKey: .extension)
        aliases = (try? c.decodeIfPresent([String].self, forKey: .aliases)) ?? []
        etag = try? c.decodeIfPresent(String.self, forKey: .etag)
        _updatedAt = try? c.decodeIfPresent(Date.self, forKey: ._updatedAt)
    }
}

/// One `emoji-custom.list` page: changed emoji plus the ids deleted since
/// the requested watermark.
public struct CustomEmojiDelta: Sendable, Equatable {
    public var update: [CustomEmoji]
    public var remove: [String]

    public init(update: [CustomEmoji] = [], remove: [String] = []) {
        self.update = update
        self.remove = remove
    }
}

/// Shortcode lookup over a server's custom emoji, kept current by applying
/// deltas. Names and aliases both resolve to the canonical emoji.
public struct CustomEmojiIndex: Sendable, Equatable {
    public private(set) var byId: [String: CustomEmoji] = [:]
    private var lookup: [String: CustomEmoji] = [:]

    public init(_ emojis: [CustomEmoji] = []) {
        apply(CustomEmojiDelta(update: emojis))
    }

    public var isEmpty: Bool { byId.isEmpty }

    /// Newest `_updatedAt` seen — the `updatedSince` for the next delta.
    public var watermark: Date? {
        byId.values.compactMap(\._updatedAt).max()
    }

    public mutating func apply(_ delta: CustomEmojiDelta) {
        for emoji in delta.update { byId[emoji._id] = emoji }
        for id in delta.remove { byId[id] = nil }
        // Rebuilt from scratch so renames and dropped aliases disappear.
        var lookup: [String: CustomEmoji] = [:]
        for emoji in byId.values {
            for alias in emoji.aliases { lookup[alias] = emoji }
        }
        // Names win over aliases on collision.
        for emoji in byId.values { lookup[emoji.name] = emoji }
        self.lookup = lookup
    }

    /// Accepts `party_parrot` or `:party_parrot:`.
    public func emoji(forShortCode shortCode: String) -> CustomEmoji? {
        lookup[shortCode.trimmingCharacters(in: CharacterSet(charactersIn: ":"))]
    }
}
