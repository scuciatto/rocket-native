import SwiftUI
import RocketChatSDK

/// Renders the server-parsed markdown AST (`Message.md`) — the message-parser
/// token tree. Walked leniently: unknown node types fall back to their raw
/// text so new server versions degrade gracefully instead of dropping content.
enum MarkdownRenderer {

    enum Block {
        case paragraph(AttributedString)
        case heading(Int, AttributedString)
        case code(language: String?, text: String)
        case quote([AttributedString])
        case list([AttributedString], ordered: Bool)
        /// A message made only of 1-3 emoji, rendered large.
        case bigEmoji(AttributedString)
    }

    /// nil when the AST is absent/empty — caller falls back to `msg`.
    static func blocks(from md: JSONValue?) -> [Block]? {
        guard let nodes = md?.arrayValue, !nodes.isEmpty else { return nil }
        let blocks = nodes.compactMap(block)
        return blocks.isEmpty ? nil : blocks
    }

    private static func block(_ node: JSONValue) -> Block? {
        switch node["type"]?.stringValue {
        case "PARAGRAPH":
            return .paragraph(inlines(node["value"]))
        case "BIG_EMOJI":
            return .bigEmoji(inlines(node["value"]))
        case "HEADING":
            let level = node["level"]?.numberValue.map(Int.init) ?? 1
            return .heading(level, inlines(node["value"]))
        case "CODE":
            let lines = node["value"]?.arrayValue?.compactMap {
                $0["value"]?["value"]?.stringValue
            } ?? []
            return .code(
                language: node["language"]?.stringValue,
                text: lines.joined(separator: "\n"))
        case "QUOTE":
            let paragraphs = node["value"]?.arrayValue?.map { inlines($0["value"]) } ?? []
            return .quote(paragraphs)
        case "UNORDERED_LIST", "ORDERED_LIST", "TASKS":
            let items = node["value"]?.arrayValue?.map { inlines($0["value"]) } ?? []
            return .list(items, ordered: node["type"]?.stringValue == "ORDERED_LIST")
        case "LINE_BREAK":
            return nil
        default:
            // Unknown block: salvage any nested text.
            let text = flattenText(node)
            return text.isEmpty ? nil : .paragraph(AttributedString(text))
        }
    }

    // MARK: - Inline nodes

    private struct Style: OptionSet {
        let rawValue: Int
        static let bold = Style(rawValue: 1 << 0)
        static let italic = Style(rawValue: 1 << 1)
        static let strike = Style(rawValue: 1 << 2)
        static let code = Style(rawValue: 1 << 3)
    }

    static func inlines(_ value: JSONValue?) -> AttributedString {
        renderInlines(value, style: [])
    }

    private static func renderInlines(_ value: JSONValue?, style: Style) -> AttributedString {
        var result = AttributedString()
        guard let nodes = value?.arrayValue else { return result }
        for node in nodes {
            result += inline(node, style: style)
        }
        return result
    }

    private static func inline(_ node: JSONValue, style: Style) -> AttributedString {
        switch node["type"]?.stringValue {
        case "PLAIN_TEXT":
            return styled(node["value"]?.stringValue ?? "", style)
        case "BOLD":
            return renderInlines(node["value"], style: style.union(.bold))
        case "ITALIC":
            return renderInlines(node["value"], style: style.union(.italic))
        case "STRIKE":
            return renderInlines(node["value"], style: style.union(.strike))
        case "INLINE_CODE":
            return styled(
                node["value"]?["value"]?.stringValue ?? "", style.union(.code))
        case "LINK":
            let src = node["value"]?["src"]?["value"]?.stringValue
                ?? node["value"]?["src"]?.stringValue ?? ""
            var label: AttributedString
            if let labelNodes = node["value"]?["label"], labelNodes.arrayValue != nil {
                label = renderInlines(labelNodes, style: style)
            } else if let single = node["value"]?["label"] {
                label = inline(single, style: style)
            } else {
                label = styled(src, style)
            }
            if let url = URL(string: src) {
                label.link = url
                label.foregroundColor = .rcFontInfo
                label.underlineStyle = .single
            }
            return label
        case "MENTION_USER":
            return mention("@" + (node["value"]?["value"]?.stringValue ?? "?"))
        case "MENTION_CHANNEL":
            return mention("#" + (node["value"]?["value"]?.stringValue ?? "?"))
        case "EMOJI":
            if let unicode = node["unicode"]?.stringValue {
                return AttributedString(unicode)
            }
            let short = node["shortCode"]?.stringValue
                ?? node["value"]?["value"]?.stringValue ?? ""
            // Text is the standard unicode, else `:name:` (also what gets
            // copied). The run is tagged so the view can swap in a server
            // custom emoji, which wins over a built-in of the same name, as in
            // the web and React Native clients. Emoticons carry their text in
            // `value`, so the custom key prefers it over `shortCode`.
            var text: AttributedString
            if let unicode = EmojiMap.unicode(forShortCode: short) {
                text = AttributedString(unicode)
            } else {
                text = styled(":\(short):", style)
            }
            text[CustomEmojiAttribute.self] = node["value"]?["value"]?.stringValue ?? short
            return text
        case "IMAGE":
            return AttributedString()   // inline images render as attachments
        default:
            return styled(flattenText(node), style)
        }
    }

    private static func styled(_ text: String, _ style: Style) -> AttributedString {
        var result = AttributedString(text)
        var font = Font.rcBody
        result.foregroundColor = .rcFontDefault
        if style.contains(.code) {
            font = .rcMono
            result.backgroundColor = Color.rcSurfaceNeutral
        }
        if style.contains(.bold) { font = font.bold() }
        if style.contains(.italic) { font = font.italic() }
        if style.contains(.strike) { result.strikethroughStyle = .single }
        result.font = font
        return result
    }

    private static func mention(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        result.font = .rcBody.weight(.semibold)
        result.foregroundColor = .rcFontInfo
        return result
    }

    /// Depth-first plain-text salvage for unknown nodes.
    private static func flattenText(_ node: JSONValue) -> String {
        switch node {
        case .string(let text):
            return text
        case .array(let items):
            return items.map(flattenText).joined()
        case .object(let fields):
            if let value = fields["value"] { return flattenText(value) }
            return ""
        default:
            return ""
        }
    }
}

/// Tags an `AttributedString` run as a custom emoji shortcode, resolved
/// against the server's `CustomEmojiStore` at render time.
enum CustomEmojiAttribute: AttributedStringKey {
    typealias Value = String
    static let name = "rocketNative.customEmoji"
}

/// Standard shortcode → unicode, the same emojibase-derived set the web and
/// React Native clients use (`EmojiShortnames.swift`).
enum EmojiMap {
    private static let table: [String: String] = {
        var table: [String: String] = [:]
        table.reserveCapacity(8_000)
        for line in emojiShortnameTable.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            table[String(line[..<tab])] = String(line[line.index(after: tab)...])
        }
        return table
    }()

    private nonisolated(unsafe) static let shortcodePattern = /:[-+_a-zA-Z0-9]+:/

    /// Plain-text surfaces (no `md` AST): swaps known `:shortcodes:` for
    /// unicode and leaves unknown ones, custom emoji included, as typed.
    static func replacingShortcodes(in text: String) -> String {
        guard text.contains(":") else { return text }
        return text.replacing(shortcodePattern) { match in
            unicode(forShortCode: String(match.output)) ?? String(match.output)
        }
    }

    static func unicode(forShortCode shortCode: String) -> String? {
        table[shortCode.trimmingCharacters(in: CharacterSet(charactersIn: ":"))]
    }
}
