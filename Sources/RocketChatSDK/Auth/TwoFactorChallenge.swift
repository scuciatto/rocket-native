import Foundation

public enum TwoFactorMethod: String, Sendable, CaseIterable {
    case totp
    case email
    case password
}

/// A pending two-factor challenge. Any REST endpoint can trip 2FA
/// (`errorType: "totp-required"`); the challenge carries the original
/// request so it can be replayed with `x-2fa-code` / `x-2fa-method` headers.
public struct TwoFactorChallenge: Sendable {
    /// Methods the server will accept for this challenge.
    public let availableMethods: [TwoFactorMethod]
    /// The method the server suggests (e.g. `.email` when a code was emailed).
    public let defaultMethod: TwoFactorMethod?
    /// True when the server already generated and emailed a code.
    public let emailCodeGenerated: Bool

    /// The original request to replay, minus 2FA headers. Internal on purpose:
    /// replaying goes through `RESTClient`.
    let request: URLRequest
    /// Endpoint path, for error reporting.
    let endpointPath: String
}
