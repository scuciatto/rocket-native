import Foundation

/// Entry point for a single Rocket.Chat server connection.
///
/// Instance-based by design: create one client per server/workspace.
/// The SDK is REST-only — live updates are delivered by an adaptive
/// delta-sync poller, not the deprecated realtime (DDP) API.
public final class RocketChatClient: Sendable {
    public let serverURL: URL
    let rest: RESTClient
    let auth: AuthSession

    public convenience init(
        serverURL: URL, transport: HTTPTransport = URLSessionTransport()
    ) {
        self.init(serverURL: serverURL, transport: transport, clock: SystemClock())
    }

    init(serverURL: URL, transport: HTTPTransport, clock: RESTClock) {
        self.serverURL = serverURL
        let auth = AuthSession()
        self.auth = auth
        self.rest = RESTClient(
            serverURL: serverURL, transport: transport, auth: auth, clock: clock)
    }

    // MARK: - Authentication

    /// Logs in with username/email + password.
    ///
    /// If the account has 2FA enabled this throws
    /// `RocketChatError.twoFactorRequired(challenge)`; prompt for a code and
    /// call `completeTwoFactorLogin(_:code:method:)` with that challenge.
    @discardableResult
    public func login(user: String, password: String) async throws -> UserProfile {
        let response = try await rest.send(API.Auth.login(user: user, password: password))
        return await adoptSession(from: response)
    }

    /// Completes a 2FA-challenged login by replaying it with the user's code.
    /// Throws `RocketChatError.twoFactorInvalid` (carrying a fresh challenge,
    /// so the user can retry) when the code is wrong.
    @discardableResult
    public func completeTwoFactorLogin(
        _ challenge: TwoFactorChallenge,
        code: String,
        method: TwoFactorMethod
    ) async throws -> UserProfile {
        let response = try await rest.replay(
            challenge, code: code, method: method, expecting: LoginResponse.self)
        return await adoptSession(from: response)
    }

    /// Asks the server to (re)send an email 2FA code.
    public func sendEmailCode(emailOrUsername: String) async throws {
        _ = try await rest.send(API.Auth.sendEmailCode(emailOrUsername: emailOrUsername))
    }

    /// Resumes a previous session from stored credentials, refreshing the token.
    @discardableResult
    public func resume(credentials: AuthCredentials) async throws -> UserProfile {
        let response = try await rest.send(API.Auth.resume(token: credentials.authToken))
        return await adoptSession(from: response)
    }

    /// Adopts a personal access token (or any token pair) without a login round trip.
    public func adopt(credentials: AuthCredentials) async {
        await auth.set(credentials)
    }

    /// Current token pair, for the caller to persist (e.g. in the Keychain).
    public var credentials: AuthCredentials? {
        get async { await auth.credentials }
    }

    public func me() async throws -> UserProfile {
        try await rest.send(API.Auth.me())
    }

    public func logout() async throws {
        _ = try? await rest.send(API.Auth.logout())
        await auth.set(nil)
    }

    private func adoptSession(from response: LoginResponse) async -> UserProfile {
        let credentials = AuthCredentials(
            authToken: response.data.authToken,
            userId: response.data.userId)
        await auth.set(credentials)
        if let me = response.data.me { return me }
        return (try? await me()) ?? UserProfile(_id: response.data.userId)
    }
}
