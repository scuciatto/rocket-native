# Rocket.Chat Native macOS Client

A native macOS Rocket.Chat client experiment with a small footprint, built as
two deliverables:

1. **`RocketChatSDK`** — a zero-dependency Swift package (this repo's root)
2. **RocketNative app** — a SwiftUI client on top (in `App/`, later phase)

## Design

**REST for requests, streamer for realtime.** Every request and action uses
the REST API (`/api/v1`). Rocket.Chat is migrating DDP *methods* to REST and
removes them in 9.0, so the SDK never calls them. The realtime DDP *streamer*
(WebSocket subscriptions) is not deprecated, and the SDK uses it for instant
messages, typing and presence. The source of truth is still *delta-sync
polling* against first-class REST endpoints:

| Tier | Endpoints | Cadence |
| --- | --- | --- |
| Sidebar (rooms, unreads) | `rooms.get` + `subscriptions.get` with `updatedSince` | ~15 s active / 60 s idle |
| Open room | `chat.syncMessages` with `lastUpdate` (inserts + edits + deletes in one call) | ~2.5 s active / 10 s idle |
| Open thread | `chat.syncThreadMessages` with `updatedSince` | same as room |

High-water marks are server `_updatedAt` timestamps, so a poll tick after
sleep or network loss is also the recovery path — there is no separate
reconnect logic. The poller honors `x-ratelimit-*` headers and backs off on
429s.

**Realtime.** `client.enableRealtime()` connects the streamer WebSocket (the
app enables it for every account), mirroring what the React Native app
subscribes to:

| Stream | Scope | Applied as |
| --- | --- | --- |
| `stream-room-messages` `<rid>` | each open room (threads ride on their room) | message upsert into the room/thread window |
| `stream-notify-room` `<rid>/deleteMessage` | each open room | message removal |
| `stream-notify-room` `<rid>/user-activity` | each open room | typing indicator (10 s expiry if a stop is lost) |
| `stream-notify-user` `subscriptions-changed`, `rooms-changed` | account | sidebar record upserts (unread badges, previews) |
| `stream-user-presence` | tracked users (DM partners) | status dots, seeded by REST `users.presence` |

Our own typing is the one stream *write* (`stream-notify-room`
`<rid>/user-activity`, throttled to one per 3 s, stop after 5 s idle); the
socket also authenticates with the streamer's `login {resume}`. Nothing else
on the socket is a request — everything else is REST.

Stream payloads never advance a high-water mark, and store upserts are
newer-wins on `_updatedAt`, so REST ticks converge whatever the socket drops
or races. While the socket is healthy, polling stretches to the idle cadence
as a safety net and live rooms skip per-message ticks; after a reconnect the
engine runs a catch-up tick and re-seeds presence. If the socket is down,
everything degrades silently to plain polling.

**Offline cache.** Stores are backed by SQLite (system `libsqlite3`, still
zero third-party dependencies) when the client is created with
`cache: .sqlite(directory:)` — one database per server host. Rooms, messages,
and delta-sync high-water marks persist, so a cold launch renders cached
history instantly and the first sync is a delta rather than a full re-sync.
The app enables this automatically (Application Support/RocketNative/,
removed on logout); `.inMemory` remains the SDK default. `rc-cli` opts in via
`RC_CACHE_DIR=<dir>`.

## SDK usage

```swift
import RocketChatSDK

let client = RocketChatClient(serverURL: URL(string: "https://chat.example.com")!)

// Login — 2FA surfaces as a typed, replayable challenge:
do {
    try await client.login(user: "felipe", password: "…")
} catch RocketChatError.twoFactorRequired(let challenge) {
    // prompt for a code for challenge.method (totp/email); a wrong code throws
    // .twoFactorInvalid with a retry challenge (same id, isRetry == true).
    try await client.completeTwoFactorLogin(challenge, code: "123456")
}

// Mid-session 2FA (protected calls like personal access tokens): install a
// provider and the SDK prompts, replays, and re-prompts on a wrong code.
// For the password method, return the plain password — the SDK sends its
// SHA-256 hex. Returning nil throws .cancelled.
struct Prompt: TwoFactorCodeProvider {
    func code(for challenge: TwoFactorChallenge) async -> String? { /* ask user */ nil }
}
await client.setTwoFactorProvider(Prompt())
let token = try await client.generatePersonalAccessToken(name: "ci")
try await client.removePersonalAccessToken(name: "ci")

// Live room list + messages:
await client.startSync()
for await rooms in await client.roomListUpdates() { /* render sidebar */ }

let room = try await client.openRoom(roomId)
for await snapshot in await room.timelineUpdates() { /* render timeline */ }
try await room.send(text: "hello")   // optimistic: appears instantly as .sending
await room.close()                   // stops polling, shrinks the window

// Realtime (instant messages, typing, presence):
await client.enableRealtime()
for await names in await room.typingUpdates() { /* "ana is typing…" */ }
await room.noteTyping()              // on composer input; throttled + auto-stop
await client.trackPresence(userIds: [peerId])
for await presence in await client.presenceUpdates() { /* status dots */ }

// Threads, search, directory:
let threads = try await client.threads(in: roomId)
let thread = try await client.openThread(threadId, in: roomId)
let hits = try await client.searchMessages(in: roomId, text: "deploy")
let global = try await client.spotlight("#random")
let people = try await client.directory(text: "ana", type: .users)
```

Credentials (`client.credentials`) are yours to persist — the app stores them
in the Keychain; the SDK never writes them anywhere.

## The app

`make run-app` builds and launches **RocketNative.app** (release, assembled
without Xcode — ~3 MB bundle, ~95 MB RSS at launch). Run `make signing-cert`
once per machine: it creates a local self-signed identity so rebuilt apps keep
the same signature and the Keychain stops asking for your password on launch.

Features: login with 2FA (TOTP + email code sheet, mid-session prompts), Keychain session resume,
live sidebar with unread/mention badges, message timeline with markdown
rendering (`md` AST), standard (~7,900 shortcodes) and custom emoji (messages, big emoji, reactions), reactions, avatars, image/file attachments, optimistic
sending with failed-state retry markers, file upload (attach button +
drag-and-drop, via rooms.media), thread inspector (reply counts, context
menu), ⌘F in-room search, ⌘K global switcher (join channels, start DMs),
sync-status badge, realtime streamer (instant messages, typing indicators in
rooms and threads, DM presence dots), and slower polling while backgrounded.

## Development

- Build: `make build` · Test: `make test` (not plain `swift test` — see Makefile)
- App bundle: `make app` (or `make run-app` to also launch it)
- Smoke tool: `swift run rc-cli` (login/rooms/history/send/tail/threads/search/spotlight/directory);
  `tail` follows a room over the streamer and prints typing (`RC_POLL=1` for polling only)
- Integration server: `cd IntegrationTests && docker compose up -d`, then
  `swift run rc-cli login http://localhost:3000 admin` (password `rc-admin-pass`)

Supported servers: Rocket.Chat 7.x and 8.x — validated live against 7.0 and
8.6.0 (full endpoint sweep, delta-sync tail, and realtime streamer). The 8.0
breaking-change wave removed no endpoint this SDK uses.
