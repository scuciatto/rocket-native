import SwiftUI
import RocketChatSDK

/// Root application state: authentication lifecycle and the live client.
@MainActor
@Observable
final class AppSession {
    enum Phase {
        case loggedOut
        case loggingIn
        /// Waiting on a 2FA code from the user.
        case twoFactor(TwoFactorChallenge)
        case active
    }

    private(set) var phase: Phase = .loggedOut
    private(set) var client: RocketChatClient?
    private(set) var profile: UserProfile?
    private(set) var credentials: AuthCredentials?
    var loginError: String?

    /// Last used server, prefilled on the login form.
    var serverURLString: String {
        didSet { UserDefaults.standard.set(serverURLString, forKey: "serverURL") }
    }

    private var pendingLogin: (server: URL, user: String)?

    init() {
        serverURLString = UserDefaults.standard.string(forKey: "serverURL")
            ?? "https://open.rocket.chat"
    }

    /// Tries to resume a stored session on launch.
    func resumeIfPossible() async {
        guard case .loggedOut = phase,
              let url = URL(string: serverURLString),
              let credentials = KeychainStore.load(server: url) else { return }
        phase = .loggingIn
        let client = RocketChatClient(serverURL: url)
        do {
            let profile = try await client.resume(credentials: credentials)
            await activate(client, profile: profile, server: url)
        } catch {
            KeychainStore.delete(server: url)
            phase = .loggedOut
        }
    }

    func login(server: String, user: String, password: String) async {
        guard let url = URL(string: server), url.scheme?.hasPrefix("http") == true else {
            loginError = "Enter a valid server URL (https://…)"
            return
        }
        serverURLString = server
        loginError = nil
        phase = .loggingIn
        let client = RocketChatClient(serverURL: url)
        self.client = client
        pendingLogin = (url, user)
        do {
            let profile = try await client.login(user: user, password: password)
            await activate(client, profile: profile, server: url)
        } catch RocketChatError.twoFactorRequired(let challenge) {
            phase = .twoFactor(challenge)
        } catch RocketChatError.notAuthenticated {
            loginError = "Invalid username or password."
            phase = .loggedOut
        } catch {
            loginError = friendlyMessage(error)
            phase = .loggedOut
        }
    }

    func submitTwoFactor(code: String, method: TwoFactorMethod) async {
        guard case .twoFactor(let challenge) = phase,
              let client, let pendingLogin else { return }
        do {
            let profile = try await client.completeTwoFactorLogin(
                challenge, code: code, method: method)
            await activate(client, profile: profile, server: pendingLogin.server)
        } catch RocketChatError.twoFactorInvalid(let fresh) {
            loginError = "Invalid code — try again."
            phase = .twoFactor(fresh)
        } catch {
            loginError = friendlyMessage(error)
            phase = .loggedOut
        }
    }

    func resendEmailCode() async {
        guard let client, let pendingLogin else { return }
        try? await client.sendEmailCode(emailOrUsername: pendingLogin.user)
    }

    func cancelTwoFactor() {
        phase = .loggedOut
        loginError = nil
    }

    func logout() async {
        if let client {
            try? await client.logout()
            await client.stopSync()
        }
        if let url = URL(string: serverURLString) {
            KeychainStore.delete(server: url)
        }
        client = nil
        profile = nil
        credentials = nil
        phase = .loggedOut
    }

    private func activate(
        _ client: RocketChatClient, profile: UserProfile, server: URL
    ) async {
        if let credentials = await client.credentials {
            KeychainStore.save(credentials, server: server)
            self.credentials = credentials
        }
        self.client = client
        self.profile = profile
        self.phase = .active
        await client.startSync()
    }

    /// Authenticated URL for a server-hosted file (uploads, image previews).
    func fileURL(path: String) -> URL? {
        guard let base = URL(string: serverURLString) else { return nil }
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(
            url: base.appending(path: relative), resolvingAgainstBaseURL: false)
        else { return nil }
        if let credentials {
            components.queryItems = [
                URLQueryItem(name: "rc_uid", value: credentials.userId),
                URLQueryItem(name: "rc_token", value: credentials.authToken),
            ]
        }
        return components.url
    }

    private func friendlyMessage(_ error: Error) -> String {
        switch error {
        case RocketChatError.network:
            return "Could not reach the server."
        case RocketChatError.httpError(let status, _, let message):
            return message ?? "Server error (\(status))."
        default:
            return "Login failed. Please try again."
        }
    }
}
