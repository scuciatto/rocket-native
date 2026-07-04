# Rocket.Chat Native macOS Client

Native macOS Rocket.Chat client: a zero-dependency Swift SDK (`RocketChatSDK`)
plus a SwiftUI app. **REST-only by explicit decision** — the realtime/DDP
streamer API is deprecated and must not be used. Live updates come from
delta-sync polling (`chat.syncMessages`, `subscriptions.get?updatedSince=`).

Full plan: `~/.claude/plans/look-ate-rocket-chat-api-piped-crayon.md`

## Commands

- Build: `make build` (or `swift build`)
- Test: `make test` — NOT plain `swift test`; this machine has CLT only (no
  Xcode), so tests need the framework search-path flags in the Makefile.
- CLI smoke tool: `swift run rc-cli <command>`
- App: `make app` assembles .build/RocketNative.app without Xcode (SPM release
  build + App/Info.plist + ad-hoc codesign); `make run-app` also launches it.
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
  a generic REST interceptor, not per-endpoint code.
