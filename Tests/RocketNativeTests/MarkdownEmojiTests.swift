import Testing
import Foundation
import RocketChatSDK
@testable import RocketNative

private func ast(_ json: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
}

@MainActor
@Suite struct MarkdownEmojiTests {
    @Test func unknownShortcodeIsTaggedAsCustomEmoji() throws {
        let inline = MarkdownRenderer.inlines(try ast("""
            [{"type": "PLAIN_TEXT", "value": "hi "},
             {"type": "EMOJI", "value": {"type": "PLAIN_TEXT", "value": "party_parrot"},
              "shortCode": "party_parrot"}]
            """))
        #expect(String(inline.characters) == "hi :party_parrot:")
        let tagged = inline.runs.compactMap { $0[CustomEmojiAttribute.self] }
        #expect(tagged == ["party_parrot"])
    }

    @Test func standardShortcodesRenderUnicodeButStayOverridable() throws {
        let inline = MarkdownRenderer.inlines(try ast("""
            [{"type": "EMOJI", "unicode": "😀"},
             {"type": "EMOJI", "value": {"type": "PLAIN_TEXT", "value": "rocket"},
              "shortCode": "rocket"}]
            """))
        #expect(String(inline.characters) == "😀🚀")
        // Literal unicode is final; a shortcode stays tagged so a custom emoji
        // named `rocket` can still replace it.
        #expect(inline.runs.compactMap { $0[CustomEmojiAttribute.self] } == ["rocket"])
    }

    @Test func fullStandardSetResolves() {
        #expect(EmojiMap.unicode(forShortCode: ":baby:") == "👶")
        #expect(EmojiMap.unicode(forShortCode: "woman_feeding_baby") != nil)
        #expect(EmojiMap.unicode(forShortCode: "+1") != nil)
        #expect(EmojiMap.unicode(forShortCode: "not_an_emoji") == nil)
    }

    @Test func plainTextReplacesOnlyKnownShortcodes() {
        #expect(EmojiMap.replacingShortcodes(in: "hi :baby: and :party_parrot: at 10:30")
            == "hi 👶 and :party_parrot: at 10:30")
    }

    @Test func bigEmojiBecomesItsOwnBlock() throws {
        let blocks = MarkdownRenderer.blocks(from: try ast("""
            [{"type": "BIG_EMOJI", "value": [
              {"type": "EMOJI", "value": {"type": "PLAIN_TEXT", "value": "pp"},
               "shortCode": "pp"}]}]
            """))
        guard case .bigEmoji(let text)? = blocks?.first else {
            Issue.record("expected .bigEmoji, got \(String(describing: blocks))")
            return
        }
        #expect(String(text.characters) == ":pp:")
    }
}
