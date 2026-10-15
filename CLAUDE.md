# Rocket.Chat Native macOS Client

Native macOS Rocket.Chat client: a zero-dependency Swift SDK (`RocketChatSDK`)
plus a SwiftUI app.

API policy (verified against server source and R&D Confluence):
- **Requests and actions: REST only** (`/api/v1`). DDP *methods* are
  deprecated and are being removed in 9.0.0 (server `methodDeprecationLogger`,
  ARCH-2166). Never call a DDP method, including through the
  `method.call/:method` REST bridge.
- **Realtime: the DDP streamer is allowed** for subscriptions (`/websocket`:
  `stream-room-messages`, `stream-notify-room|user|logged`,
  `stream-user-presence`), including stream writes such as typing. The
  streamer is *not* deprecated: it is an SLO-tracked core service and new
  features (presence sync) ship on it. Use it for a better experience:
  instant messages, typing, live presence, read receipts.
- **REST delta sync stays the source of truth and the recovery path**
  (`chat.syncMessages`, `subscriptions.get?updatedSince=`). Stream events
  may be applied immediately, but they must converge with the next REST
  tick. Any missed event is repaired by sync. If the socket is down,
  behavior degrades to plain polling.
- The socket (`StreamerTransport`, enabled per account) carries payloads:
  room messages/deletes/typing for open rooms, sidebar records, presence for
  tracked users. Stream data never advances a REST high-water mark, and store
  upserts are newer-wins on `_updatedAt`, so REST converges races.
- The only `msg:"method"` frames allowed on the socket are the streamer's
  own `login {resume}` (socket auth) and the `stream-notify-room`
  `<rid>/user-activity` typing write (the server rejects other stream writes;
  legacy `<rid>/typing` is dropped). Neither is deprecation-logged.

Full plan: `~/.claude/plans/look-ate-rocket-chat-api-piped-crayon.md`
Backlog: `BACKLOG.md`, mirrored to the app's default GitHub project:
https://github.com/users/scuciatto/projects/2 ("Rocket Native Development").
Keep the two in sync when adding backlog items (`gh project item-create 2
--owner scuciatto --title ... --body ...`).

## Commands

- Build: `make build` (or `swift build`)
- Test: `make test` — NOT plain `swift test`. It pins the Command Line Tools
  toolchain (`DEVELOPER_DIR`) plus framework search-path flags; Xcode's
  toolchain can't use the CLT Testing macros and fails codesigning the
  .xctest in this folder.
- CLI smoke tool: `swift run rc-cli <command>`
- App: `make app` assembles .build/RocketNative.app without Xcode (SPM release
  build + App/Info.plist + codesign); `make run-app` also launches it.
  `make signing-cert` (once per machine) creates the stable self-signed
  identity `app` signs with; without it the build is ad-hoc and every rebuild
  re-triggers Keychain password prompts.
- Local server: `cd IntegrationTests && docker compose up -d` → admin /
  rc-admin-pass at http://localhost:3000.

## Conventions

- Swift 6 language mode, strict concurrency. All public SDK types `Sendable`.
- Zero third-party dependencies (URLSession, Foundation, Security only).
- SDK is UI-framework-free: no SwiftUI/Combine imports in `Sources/RocketChatSDK`;
  state is exposed via `AsyncStream` snapshots.
- Instance-based, no singletons (`RocketChatClient(serverURL:)` per server).
- Swift Testing (`import Testing`), not XCTest (XCTest is unavailable on CLT).
- Models decode leniently: unknown enum values map to `.unknown`, dates handle
  both ISO-8601 and `{"$date": ms}`.
- Never send `query`/`fields` REST params (disabled in Rocket.Chat 7.x).
- 2FA (`totp-required` → replay with `x-2fa-code`/`x-2fa-method`) is handled by
  a generic REST interceptor, not per-endpoint code. Login reports it as HTTP
  401 with the code in `error` (other routes: 400 + `errorType`); any other
  login 401 stays `.notAuthenticated`. Mid-session challenges on
  authenticated calls go to the installed `TwoFactorCodeProvider` (nil →
  `.cancelled`, a silent no-op for callers); login never uses it. The
  `password` method sends the lowercase SHA-256 hex of the password.
- Custom emoji come from `emoji-custom.list` delta sync (`CustomEmojiIndex`);
  look up by name **and** aliases (reaction keys may be aliases). The image
  route `/emoji-custom/<name>.<ext>?etag=` is unauthenticated, always uses the
  canonical name, and serves GIFs labelled as JPEG (decode by bytes).
- Standard emoji shortcodes resolve via `EmojiMap`, backed by the generated
  `EmojiShortnames.swift` (React Native's emojibase table; regenerate with
  `scripts/generate-emoji-shortnames.py`, never edit by hand). A custom emoji
  with the same name wins over the built-in.
