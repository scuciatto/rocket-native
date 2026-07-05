# Rocket.Chat Native macOS Client

A native macOS Rocket.Chat client experiment with a small footprint, built as
two deliverables:

1. **`RocketChatSDK`** — a zero-dependency Swift package (this repo's root)
2. **RocketNative app** — a SwiftUI client on top (in `App/`, later phase)

## Design

**REST-only.** The realtime (DDP/streamer) WebSocket API is deprecated, so the
SDK never touches it. Live updates come from *delta-sync polling* against
first-class REST endpoints:

| Tier | Endpoints | Cadence |
| --- | --- | --- |
| Sidebar (rooms, unreads) | `rooms.get` + `subscriptions.get` with `updatedSince` | ~15 s active / 60 s idle |
| Open room | `chat.syncMessages` with `lastUpdate` (inserts + edits + deletes in one call) | ~2.5 s active / 10 s idle |
| Open thread | `chat.syncThreadMessages` with `updatedSince` | same as room |

High-water marks are server `_updatedAt` timestamps, so a poll tick after
sleep or network loss is also the recovery path — there is no separate
reconnect logic. The poller honors `x-ratelimit-*` headers and backs off on
429s.

**Known v1 limitations** (consequences of REST-only): there are no typing
indicators (streamer-only feature today).

**Push signals (opt-in).** `client.enablePushSignals()` attaches a *bell*:
the legacy realtime WebSocket subscribed to the two user-level notify streams
and reduced to "something changed" hints — it never carries message data, and
every payload still flows through REST delta sync. Signals trigger immediate
ticks (sub-second updates); polling continues at the idle cadence as a safety
net, so a failed socket degrades silently to plain polling. When Rocket.Chat
ships the streamer's REST-era replacement, it becomes another `PushSignaling`
implementation and `StreamerSignalTransport` gets deleted.

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
    // prompt the user for a code (challenge.availableMethods: totp/email)
    try await client.completeTwoFactorLogin(challenge, code: "123456", method: .totp)
}

// Live room list + messages:
await client.startSync()
for await rooms in await client.roomListUpdates() { /* render sidebar */ }

let room = try await client.openRoom(roomId)
for await snapshot in await room.timelineUpdates() { /* render timeline */ }
try await room.send(text: "hello")   // optimistic: appears instantly as .sending
await room.close()                   // stops polling, shrinks the window

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

`make run-app` builds and launches **RocketNative.app** (release, ad-hoc
signed, assembled without Xcode — ~3 MB bundle, ~95 MB RSS at launch).

Features: login with 2FA (TOTP + email code sheet), Keychain session resume,
live sidebar with unread/mention badges, message timeline with markdown
rendering (`md` AST), reactions, avatars, image/file attachments, optimistic
sending with failed-state retry markers, thread inspector (reply counts,
context menu), ⌘F in-room search, ⌘K global switcher (join channels, start
DMs), sync-status badge, and slower polling while backgrounded.

## Development

- Build: `make build` · Test: `make test` (not plain `swift test` — see Makefile)
- App bundle: `make app` (or `make run-app` to also launch it)
- Smoke tool: `swift run rc-cli` (login/rooms/history/send/tail/threads/search/spotlight/directory)
- Integration server: `cd IntegrationTests && docker compose up -d`, then
  `swift run rc-cli login http://localhost:3000 admin` (password `rc-admin-pass`)

Supported servers: Rocket.Chat 6.x/7.x (validated live against 7.0).
