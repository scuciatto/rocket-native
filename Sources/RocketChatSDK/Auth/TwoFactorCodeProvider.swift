import Foundation

/// Supplies codes for 2FA challenges raised mid-session by protected REST
/// calls (e.g. personal access tokens, password changes). Install one with
/// `RocketChatClient.setTwoFactorProvider(_:)`; the SDK then prompts and
/// replays transparently, re-prompting on a wrong code.
///
/// Only authenticated calls consult the provider. Login keeps its explicit
/// flow: it throws `.twoFactorRequired` and the caller replays with
/// `completeTwoFactorLogin(_:code:method:)`.
public protocol TwoFactorCodeProvider: Sendable {
    /// Ask the user for a code. nil cancels the call (it throws `.cancelled`).
    /// A retry after a rejected code arrives with the same `id` and
    /// `isRetry == true`.
    func code(for challenge: TwoFactorChallenge) async -> String?
    /// The challenge is over: accepted, cancelled, or failed with a
    /// non-retryable error. Called exactly once per challenge.
    func challengeEnded(_ challenge: TwoFactorChallenge) async
}

extension TwoFactorCodeProvider {
    public func challengeEnded(_ challenge: TwoFactorChallenge) async {}
}
