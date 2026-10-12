# Backlog

Deferred items from the v1 plan, plus gaps noted during implementation.
Roughly ordered by expected value.

## From the plan's post-v1 backlog

1. ~~**Offline cache (GRDB/SQLite)**~~ — **done** (feature/offline-cache-sqlite):
   SQLite-backed stores via the system `libsqlite3` (no GRDB dependency needed),
   persisted sync marks, per-host db enabled by the app and cleared on logout.
   Follow-up noted below (#19).
2. ~~**Notifications**~~ — **done** (feature/notifications): snapshot-diff
   planner over the sidebar poll drives banners (sender/room/preview, sound
   for DMs and mentions, suppressed for the on-screen room) and the Dock
   badge (personal count, dot for channel chatter); clicking a banner opens
   the room.
3. ~~**Push transport**~~ — **done** (feature/push-signal): `PushSignaling`
   seam in the engine + opt-in `StreamerSignalTransport` bell (streamer used
   for wake-up hints only, zero payloads; REST stays the data path; polling
   stretches to a safety net while healthy). 0.17 s live delivery vs the
   2.5 s poll bound. Typing indicators remain out (would require payloads).
4. ~~**Multi-server/workspace UI**~~ — **done** (feature/multi-server):
   vertical server rail (lateral tabs; horizontal space reserved for future
   conversation tabs), all accounts live concurrently, aggregated
   notifications/Dock badge, ⌘1…⌘9 switching, add-server sheet, per-server
   logout. Rail hidden with a single server.
5. ~~**File upload**~~ — **done** (feature/file-upload): `rooms.media` +
   `rooms.mediaConfirm` two-step flow (works on 7.x and 8.x), attach button
   and drag-and-drop in the app, thread uploads via `tmid`. Paste-image
   support remains a follow-up.

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
15. ~~**Jump-to-message from search**~~ — **done**: selecting a main-timeline
    search hit pages history until the message is in the window
    (`RoomHandle.loadOlder(until:)`, capped at `jumpWindowLimit`), then
    scrolls to and flashes the row; thread-reply hits open their thread,
    rooted at the real parent via the new `chat.getMessage` client call.
16. **`chat.syncMessages` cursor mode** — newer 7.x cursor pagination
    (`next`/`previous`) isn't used; legacy `lastUpdate` mode works but the
    cursor path is the documented forward direction.
17. ~~**Unread separator / mark-unread**~~ — **done** (feature/unread-separator):
    red "New" divider anchored at the last-seen timestamp captured on open
    (skips own messages), arrivals keep the room read while on screen, and
    the sidebar context menu gains Mark as Read/Unread (subscriptions.unread
    with an immediate sidebar catch-up).
18. **Composer markdown authoring** — markdown typed in the composer passes
    through and renders (server-parsed), but there are no authoring aids:
    add ⌘B/⌘I/⌘⇧X selection wrapping, a code-fence helper, and optionally a
    live preview toggle. Note: optimistic sends show raw text until the
    server echo arrives with the parsed `md` AST (sub-second).
17. **Unread separator / mark-unread** — rooms mark read on open+send;
    there's no "new messages" divider or manual mark-unread.
18. ~~**Composer markdown authoring**~~ — **done** (feature/composer-markdown):
    ⌘B/⌘I/⌘⇧X/⌘⇧C selection wrapping (with unwrap toggle) via the focused
    field editor, code-fence helper, and a preview toggle using Foundation's
    CommonMark parser. Formatting strip appears only while composing.
19. **Cache follow-ups** — edits/deletes that happen while the client is
    offline are only reconciled for the newest page of each room (room-tier
    sync resumes from the fetched page, not the persisted mark, to avoid
    unbounded catch-up responses); consider bounded backfill. Also: cache
    size cap/pruning for very active workspaces.
20. **Login 2FA on server 9.0** — from 9.0, `applyBreakingChanges` strips the
    login error body to `{success:false,error:'unauthorized'}`, which would
    make login 2FA undetectable (it'd read as a wrong password). Re-check the
    login 401 envelope when 9.0 ships.
21. **2FA management screen** — turn TOTP / email 2FA on and off from the
    app (React Native has no such screen either). The SDK already answers
    mid-session challenges via `TwoFactorCodeProvider`.
22. **PAT login and management UI** — extends #11: list/create/remove
    personal access tokens in the app (SDK has create/remove; `rc-cli pat`
    exercises them) and offer PAT sign-in on the login form.
23. **Custom emoji picker and autocomplete** — custom emoji render in
    messages and reactions, but can't be chosen: add them to the reaction
    menu/picker and a `:` autocomplete in the composer (insert `:name:`;
    React with the bare name via `chat.react`).
24. **Animated custom emoji** — `Text(Image)` shows only a GIF's first
    frame; animating needs an `NSTextView`-based message renderer.
25. **Persist custom emoji** — the list is re-fetched in full on each launch
    (one request); store it in the SQLite cache and resume from the
    watermark if large workspaces make that slow.

## Known v1 limitations (accepted, documented in README)

- Update latency: ~2–3 s active room, ~15–30 s sidebar (polling).
- No typing indicators (streamer-only feature today).
- No offline mode until item 1 lands.
