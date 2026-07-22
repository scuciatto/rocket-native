import Testing
import Foundation
@testable import RocketNative

/// Unit tests for the pure `@mention` token scanner. Caret positions are
/// UTF-16 offsets (what the field editor reports).
@MainActor
@Suite struct MentionScannerTests {
    @Test func detectsTokenAtEnd() {
        let hit = MentionController.scan(text: "@ali", caretUTF16: 4)
        #expect(hit?.term == "ali")
        #expect(hit?.range == NSRange(location: 0, length: 4))   // covers "@ali"
    }

    @Test func detectsTokenAfterWhitespace() {
        let hit = MentionController.scan(text: "hi @bob", caretUTF16: 7)
        #expect(hit?.term == "bob")
        #expect(hit?.range == NSRange(location: 3, length: 4))
    }

    @Test func shortTermIsBelowQueryThreshold() {
        // The scanner still detects it; the controller gates on length.
        let hit = MentionController.scan(text: "@al", caretUTF16: 3)
        #expect(hit?.term == "al")
        #expect(hit!.term.count < MentionController.minTermLength)
    }

    @Test func emailDoesNotTrigger() {
        #expect(MentionController.scan(text: "email@host", caretUTF16: 10) == nil)
    }

    @Test func caretAfterTrailingSpaceHasNoToken() {
        #expect(MentionController.scan(text: "@ali ", caretUTF16: 5) == nil)
    }

    @Test func caretBeforeAtHasNoToken() {
        #expect(MentionController.scan(text: "@abc", caretUTF16: 0) == nil)
    }

    @Test func caretInMiddleCoversWholeToken() {
        let hit = MentionController.scan(text: "@alice", caretUTF16: 3)   // @al|ice
        #expect(hit?.term == "alice")
        #expect(hit?.range == NSRange(location: 0, length: 6))
    }

    @Test func usernamePunctuationIsPartOfToken() {
        let hit = MentionController.scan(text: "@a.b-c_d", caretUTF16: 8)
        #expect(hit?.term == "a.b-c_d")
    }

    @Test func resolvesTokenUnderCaretAmongMany() {
        let hit = MentionController.scan(text: "@foo @bar", caretUTF16: 9)
        #expect(hit?.term == "bar")
        #expect(hit?.range == NSRange(location: 5, length: 4))
    }

    @Test func outOfBoundsCaretIsSafe() {
        #expect(MentionController.scan(text: "@ali", caretUTF16: 99) == nil)
    }
}
