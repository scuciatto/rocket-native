import CryptoKit
import Foundation

public enum TwoFactorMethod: String, Sendable, CaseIterable {
    case totp
    case email
    /// Fallback for accounts without 2FA enrolled: the user re-enters their
    /// account password, sent as its SHA-256 hex digest.
    case password

    /// The `x-2fa-code` header value for a user-entered code. The password
    /// method expects the lowercase SHA-256 hex of the password; other codes
    /// go as typed (TOTP also accepts backup codes, so no digit filtering).
    func headerValue(for code: String) -> String {
        switch self {
        case .password:
            SHA256.hash(data: Data(code.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        case .totp, .email:
            code.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// A pending two-factor challenge. Any protected REST endpoint can trip 2FA
/// (HTTP 400 `errorType: "totp-required"`; login uses HTTP 401 with the code
/// in `error`); the challenge carries the original request so it can be
/// replayed with `x-2fa-code` / `x-2fa-method` headers.
public struct TwoFactorChallenge: Sendable, Identifiable {
    /// Stable across retries of the same challenge (`totp-invalid` keeps it),
    /// so a UI can update its prompt in place.
    public let id: UUID
    /// Methods the server will accept for this challenge.
    public let availableMethods: [TwoFactorMethod]
    /// The method the server suggests (e.g. `.email` when a code was emailed).
    public let defaultMethod: TwoFactorMethod?
    /// True when the server already generated and emailed a code.
    public let emailCodeGenerated: Bool
    /// Identity to pass to `sendEmailCode(emailOrUsername:)` for a resend.
    /// Sent by the server on login challenges.
    public let emailOrUsername: String?
    /// True when this challenge follows a rejected code (`totp-invalid`).
    public let isRetry: Bool

    /// The method the code will be verified with. At login the server always
    /// uses its first active method, so offering a picker would mislead.
    public var method: TwoFactorMethod {
        defaultMethod ?? availableMethods.first ?? .totp
    }

    /// The original request to replay, minus 2FA headers. Internal on purpose:
    /// replaying goes through `RESTClient`.
    let request: URLRequest
    /// Endpoint path, for error reporting.
    let endpointPath: String

    init(
        id: UUID = UUID(),
        availableMethods: [TwoFactorMethod],
        defaultMethod: TwoFactorMethod?,
        emailCodeGenerated: Bool,
        emailOrUsername: String?,
        isRetry: Bool,
        request: URLRequest,
        endpointPath: String
    ) {
        self.id = id
        self.availableMethods = availableMethods
        self.defaultMethod = defaultMethod
        self.emailCodeGenerated = emailCodeGenerated
        self.emailOrUsername = emailOrUsername
        self.isRetry = isRetry
        self.request = request
        self.endpointPath = endpointPath
    }

    /// A retry of `previous`: keeps its `id`, and fills in the methods and
    /// identity when the `totp-invalid` body carried no details.
    func inheriting(from previous: TwoFactorChallenge) -> TwoFactorChallenge {
        TwoFactorChallenge(
            id: previous.id,
            availableMethods: availableMethods.isEmpty
                ? previous.availableMethods : availableMethods,
            defaultMethod: defaultMethod ?? previous.defaultMethod,
            emailCodeGenerated: emailCodeGenerated,
            emailOrUsername: emailOrUsername ?? previous.emailOrUsername,
            isRetry: isRetry,
            request: previous.request,
            endpointPath: previous.endpointPath)
    }
}
