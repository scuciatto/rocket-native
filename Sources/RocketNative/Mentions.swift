import Foundation
import RocketChatSDK

/// Drives the composer's `@mention` autocomplete: scans the draft around the
/// caret for an active mention token, debounces a workspace user query once
/// the term is long enough, and tracks the highlighted row.
///
/// The scanner (`scan`) is a pure static function so it unit-tests without a
/// view — mirroring `TimelineList.firstUnreadId`.
@Observable
@MainActor
final class MentionController {
    /// Minimum characters after `@` before we query (saves early keystrokes).
    static let minTermLength = 3

    private(set) var results: [MentionUser] = []
    /// UTF-16 range of the active `@term` (including the `@`), or nil when no
    /// mention token is under the caret.
    private(set) var activeRange: NSRange?
    private(set) var term = ""
    var selection = 0

    private var queryTask: Task<Void, Never>?

    /// Interactable only when a token is active AND we have rows to show.
    var isVisible: Bool { activeRange != nil && !results.isEmpty }

    /// Re-scans for a mention token at `caretUTF16`; when one of at least
    /// `minTermLength` chars is present, debounces then runs `search`. A
    /// shorter or absent token clears the results (hiding the popup).
    func update(
        text: String, caretUTF16: Int,
        search: @escaping (String) async throws -> [MentionUser]
    ) {
        guard let hit = Self.scan(text: text, caretUTF16: caretUTF16) else {
            dismiss()
            return
        }
        activeRange = hit.range
        term = hit.term
        guard hit.term.count >= Self.minTermLength else {
            // Token present but too short: keep it active, show nothing yet.
            queryTask?.cancel()
            results = []
            return
        }
        queryTask?.cancel()
        queryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))   // debounce
            guard !Task.isCancelled else { return }
            let users = (try? await search(hit.term)) ?? []
            guard !Task.isCancelled else { return }
            self?.results = users
            self?.selection = 0
        }
    }

    /// Moves the highlight, clamped (no wrap-around).
    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(0, selection + delta), results.count - 1)
    }

    var selectedUser: MentionUser? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    func dismiss() {
        queryTask?.cancel()
        queryTask = nil
        results = []
        activeRange = nil
        term = ""
        selection = 0
    }

    // MARK: - Pure scanner

    /// Finds the `@mention` token under the caret, if any. Works entirely in
    /// UTF-16/NSString units so the returned range feeds
    /// `NSTextView.insertText(_:replacementRange:)` directly.
    ///
    /// A token qualifies when: the `@` is at string start or immediately
    /// preceded by whitespace (so `email@host` never triggers), the run after
    /// it is username characters `[A-Za-z0-9._-]`, and the caret sits strictly
    /// after the `@` within/at the end of that run.
    static func scan(text: String, caretUTF16 caret: Int) -> (range: NSRange, term: String)? {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length else { return nil }
        let atCode = UInt16(UInt8(ascii: "@"))

        // Walk left from the caret over username characters.
        var start = caret
        while start > 0, let scalar = Unicode.Scalar(ns.character(at: start - 1)),
              isUsernameChar(scalar) {
            start -= 1
        }

        // The character just left of the run must be '@'.
        guard start > 0, ns.character(at: start - 1) == atCode else { return nil }
        let atIndex = start - 1

        // '@' must start the string or follow whitespace/newline.
        if atIndex > 0 {
            guard let before = Unicode.Scalar(ns.character(at: atIndex - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(before) else { return nil }
        }

        // Caret must be strictly after the '@' (i.e. within the term).
        guard caret > atIndex else { return nil }

        // Extend right past the caret to cover the whole token.
        var end = caret
        while end < ns.length, let scalar = Unicode.Scalar(ns.character(at: end)),
              isUsernameChar(scalar) {
            end += 1
        }

        let range = NSRange(location: atIndex, length: end - atIndex)
        let term = ns.substring(with: NSRange(
            location: atIndex + 1, length: end - atIndex - 1))
        return (range, term)
    }

    private static func isUsernameChar(_ s: Unicode.Scalar) -> Bool {
        (s >= "A" && s <= "Z") || (s >= "a" && s <= "z")
            || (s >= "0" && s <= "9") || s == "." || s == "_" || s == "-"
    }
}
