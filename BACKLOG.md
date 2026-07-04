# Backlog

Deferred items from the v1 plan, plus gaps noted during implementation.
Roughly ordered by expected value.

## From the plan's post-v1 backlog

1. **Offline cache (GRDB/SQLite)** — replace `InMemoryRoomStore` /
   `InMemoryMessageStore` behind the existing `RoomStoring` / `MessageStoring`
   protocols. Buys offline history, instant cold launch, and less re-sync
   traffic. The delta endpoints (`updatedSince` / `lastUpdate` high-water
   marks) were designed for exactly this.
2. **Notifications** — local notifications from the sidebar poll
   (`stream-notify-user` is streamer-only, but `subscriptions.get` deltas
   carry unread/mention changes). Badge count on the Dock icon.
3. **Push transport** — when Rocket.Chat ships the streamer's REST-era
   replacement, slot it in behind the `SyncEngine` seam; polling remains the
   fallback. Removes the 2–3 s latency and enables typing indicators.
4. **Multi-server/workspace UI** — the SDK is instance-based already
   (`RocketChatClient` per server); this is account-switcher UI + per-server
   Keychain items (already keyed by host).
5. **File upload** — `rooms.upload` endpoint + drag-and-drop/paste in the
   composer.

## Open questions from the plan (still open)

6. **Distribution** — currently ad-hoc signed via `make app`. Developer ID +
   notarized DMG needs a signing identity (and likely a real Xcode project,
   see below).
7. **Email 2FA end-to-end test** — unit-tested only; needs an SMTP-configured
   server. TOTP can be tested by enabling it on a user in the compose stack.
8. **Timeline scroll spike** — the plan called for an explicit check of
   bottom-anchored `ScrollView`/`LazyVStack` under load (prepend jitter,
   scroll retention). If it fails, swap the timeline container for
   `NSTableView` in `NSViewRepresentable`, keeping SwiftUI cells.
9. **Memory profiling with a large room** — target < 150 MB RSS. Launch
   footprint is ~96 MB; needs an Instruments pass against a high-traffic room.

## Gaps noticed during implementation

10. **Xcode project** — this machine has CLT only, so the app is an SPM
    executable + `make app` bundling. Fine for development; revisit for asset
    catalogs, previews, and notarization workflows.
11. **Personal Access Token login in the app** — SDK supports it
    (`adopt(credentials:)`); the login form doesn't offer it yet (planned as
    an "advanced" option).
12. **Message actions in the UI** — SDK has `edit`, `delete`, `react`; the
    app renders reactions but offers no edit/delete/react affordances yet.
13. **Emoji coverage** — `EmojiMap` bundles ~60 common shortcodes; everything
    else renders as `:shortcode:`. Consider bundling the full emoji-shortname
    table (or the server's custom-emoji endpoint).
14. **KaTeX / task lists** — render as plain text (per plan, acceptable v1).
15. **Jump-to-message from search** — in-room search results currently open
    the message's thread; jumping the main timeline to an arbitrary older
    message (with history windowing around it) is not implemented.
16. **`chat.syncMessages` cursor mode** — newer 7.x cursor pagination
    (`next`/`previous`) isn't used; legacy `lastUpdate` mode works but the
    cursor path is the documented forward direction.
17. **Unread separator / mark-unread** — rooms mark read on open+send;
    there's no "new messages" divider or manual mark-unread.
18. **Composer markdown authoring** — markdown typed in the composer passes
    through and renders (server-parsed), but there are no authoring aids:
    add ⌘B/⌘I/⌘⇧X selection wrapping, a code-fence helper, and optionally a
    live preview toggle. Note: optimistic sends show raw text until the
    server echo arrives with the parsed `md` AST (sub-second).

## Known v1 limitations (accepted, documented in README)

- Update latency: ~2–3 s active room, ~15–30 s sidebar (polling).
- No typing indicators (streamer-only feature today).
- No offline mode until item 1 lands.
