import Foundation

/// Auth token pair for the `X-Auth-Token` / `X-User-Id` headers.
/// The SDK never persists these; storage (e.g. Keychain) is the caller's job.
public struct AuthCredentials: Codable, Sendable, Equatable {
    public let authToken: String
    public let userId: String

    public init(authToken: String, userId: String) {
        self.authToken = authToken
        self.userId = userId
    }
}
