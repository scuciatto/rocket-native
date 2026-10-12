import Foundation

struct CustomEmojiListResponse: Decodable, Sendable {
    struct Removed: Decodable, Sendable {
        var _id: String
    }

    struct Emojis: Decodable, Sendable {
        var update: [CustomEmoji]
        /// Trash records (full documents plus `_deletedAt`); only ids matter.
        var remove: [Removed]?

        private enum CodingKeys: String, CodingKey { case update, remove }

        /// Drops malformed records instead of failing the whole list.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            update = (try c.decode([Lossy<CustomEmoji>].self, forKey: .update))
                .compactMap(\.value)
            remove = (try? c.decodeIfPresent([Lossy<Removed>].self, forKey: .remove))?
                .compactMap(\.value)
        }
    }

    private struct Lossy<T: Decodable & Sendable>: Decodable, Sendable {
        var value: T?
        init(from decoder: Decoder) throws {
            value = try? T(from: decoder)
        }
    }

    var emojis: Emojis
}

extension API {
    enum EmojiCustom {
        /// Full list without `updatedSince`; otherwise changes and deletions
        /// after it.
        static func list(updatedSince: Date? = nil) -> Endpoint<CustomEmojiListResponse> {
            var query: [URLQueryItem] = []
            if let updatedSince {
                query.append(URLQueryItem(
                    name: "updatedSince", value: RCJSON.syncTimestamp(updatedSince)))
            }
            return .get("emoji-custom.list", query: query)
        }
    }
}
