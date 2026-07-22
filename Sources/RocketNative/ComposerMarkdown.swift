import AppKit
import SwiftUI

/// Markdown authoring commands for the composer. SwiftUI's TextField has no
/// selection API on macOS, but its backing field editor is an NSTextView —
/// commands operate on the focused editor (wrapping the selection, keeping
/// the caret sensible) and fall back to appending markers to the binding
/// when nothing is focused. Edits go through `insertText`, so the SwiftUI
/// binding stays in sync via the normal text-change path.
@MainActor
enum ComposerMarkdown {
    struct Style {
        let marker: String
        let icon: String
        let help: String

        static let bold = Style(marker: "**", icon: "bold", help: "Bold (⌘B)")
        static let italic = Style(marker: "_", icon: "italic", help: "Italic (⌘I)")
        static let strike = Style(
            marker: "~~", icon: "strikethrough", help: "Strikethrough (⌘⇧X)")
        static let inlineCode = Style(
            marker: "`", icon: "chevron.left.forwardslash.chevron.right",
            help: "Inline code (⌘⇧C)")
    }

    /// Wraps (or unwraps) the current selection with `marker`; with an empty
    /// selection, inserts a marker pair and puts the caret between them.
    static func toggle(_ style: Style, fallback: Binding<String>) {
        guard let editor = focusedEditor() else {
            fallback.wrappedValue += style.marker + style.marker
            return
        }
        let marker = style.marker
        let range = editor.selectedRange()
        let text = editor.string as NSString
        let selected = text.substring(with: range)

        if selected.hasPrefix(marker), selected.hasSuffix(marker),
           selected.count >= marker.count * 2 {
            // Unwrap an already-wrapped selection.
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            editor.insertText(inner, replacementRange: range)
            editor.setSelectedRange(NSRange(
                location: range.location, length: (inner as NSString).length))
        } else {
            editor.insertText(marker + selected + marker, replacementRange: range)
            let markerLength = (marker as NSString).length
            editor.setSelectedRange(NSRange(
                location: range.location + markerLength,
                length: (selected as NSString).length))
        }
    }

    /// The focused editor's current selection (caret when zero-length), in
    /// UTF-16/NSRange units — for caret-aware features like `@mention`.
    static func currentSelection() -> NSRange? { focusedEditor()?.selectedRange() }

    /// Replaces `range` with `string` in the focused editor and drops the
    /// caret just after the inserted text. Goes through `insertText`, so the
    /// SwiftUI binding stays in sync via the normal text-change path.
    static func replaceRange(_ range: NSRange, with string: String) {
        guard let editor = focusedEditor() else { return }
        editor.insertText(string, replacementRange: range)
        editor.setSelectedRange(NSRange(
            location: range.location + (string as NSString).length, length: 0))
    }

    /// Inserts a fenced code block, placing the caret inside.
    static func insertCodeFence(fallback: Binding<String>) {
        guard let editor = focusedEditor() else {
            fallback.wrappedValue += "\n```\n\n```"
            return
        }
        let range = editor.selectedRange()
        let selected = (editor.string as NSString).substring(with: range)
        let block = "```\n\(selected)\n```"
        editor.insertText(block, replacementRange: range)
        editor.setSelectedRange(NSRange(
            location: range.location + 4 + (selected as NSString).length, length: 0))
    }

    /// Client-side preview of the draft. Foundation's CommonMark parser
    /// covers bold/italic/strike/code/links — close enough to the server's
    /// rendering for a preview (mentions/emoji render as plain text).
    static func preview(of draft: String) -> AttributedString {
        (try? AttributedString(
            markdown: draft,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: false,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(draft)
    }

    private static func focusedEditor() -> NSTextView? {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
              editor.isFieldEditor || editor.isEditable else { return nil }
        return editor
    }
}
