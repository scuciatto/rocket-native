import SwiftUI
import RocketChatSDK

/// One signed-in workspace: its client, identity, and UI state. All accounts
/// stay live concurrently (each polls its own sidebar), so badges and
/// notifications work across servers, not just the visible one.
@MainActor
@Observable
final class ServerAccount: Identifiable {
    /// Server host — also the Keychain account and cache-file key.
    let id: String
    let serverURL: URL
    let client: RocketChatClient
    /// The SQLite cache could not open; this account runs in-memory.
    let cacheUnavailable: Bool
    private(set) var profile: UserProfile
    private(set) var credentials: AuthCredentials?
    /// Sidebar selection, kept so switching servers and back restores context.
    var selectedRoomId: String?

    init(
        serverURL: URL, client: RocketChatClient, cacheUnavailable: Bool,
        profile: UserProfile, credentials: AuthCredentials?
    ) {
        self.id = serverURL.host() ?? serverURL.absoluteString
        self.serverURL = serverURL
        self.client = client
        self.cacheUnavailable = cacheUnavailable
        self.profile = profile
        self.credentials = credentials
    }

    /// Short label for the server rail ("open" for open.rocket.chat).
    var displayName: String {
        let host = id.hasPrefix("www.") ? String(id.dropFirst(4)) : id
        return host.split(separator: ".").first.map(String.init) ?? host
    }

    var railInitial: String {
        String(displayName.prefix(1)).uppercased()
    }

    /// Authenticated URL for a server-hosted file (uploads, image previews).
    func fileURL(path: String) -> URL? {
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(
            url: serverURL.appending(path: relative), resolvingAgainstBaseURL: false)
        else { return nil }
        if let credentials {
            components.queryItems = [
                URLQueryItem(name: "rc_uid", value: credentials.userId),
                URLQueryItem(name: "rc_token", value: credentials.authToken),
            ]
        }
        return components.url
    }
}

/// Root application state: the set of signed-in workspaces plus the login
/// flow for adding one (first run and "add server" share it).
@MainActor
@Observable
final class AppSession {
    enum LoginFlow {
        case idle
        case loggingIn
        /// Waiting on a 2FA code from the user.
        case twoFactor(TwoFactorChallenge)
    }

    private(set) var accounts: [ServerAccount] = []
    var activeAccountId: String? {
        didSet { UserDefaults.standard.set(activeAccountId, forKey: "activeServer") }
    }
    /// True while stored sessions are being resumed at launch.
    private(set) var isResuming = false
    private(set) var loginFlow: LoginFlow = .idle
    /// Presents the add-server login sheet.
    var showAddServer = false
    let notifications = NotificationManager()
    var loginError: String?

    /// Last used server, prefilled on the login form.
    var serverURLString: String {
        didSet { UserDefaults.standard.set(serverURLString, forKey: "serverURL") }
    }

    private var pendingLogin:
        (server: URL, user: String, client: RocketChatClient, cacheUnavailable: Bool)?

    init() {
        serverURLString = UserDefaults.standard.string(forKey: "serverURL")
            ?? "https://open.rocket.chat"
    }

    var activeAccount: ServerAccount? {
        accounts.first { $0.id == activeAccountId } ?? accounts.first
    }

    // MARK: - Facade for room-level views (always the active account)

    var client: RocketChatClient? { activeAccount?.client }
    var profile: UserProfile? { activeAccount?.profile }
    var cacheUnavailable: Bool { activeAccount?.cacheUnavailable ?? false }

    func fileURL(path: String) -> URL? {
        activeAccount?.fileURL(path: path)
    }

    // MARK: - Login / resume

    /// Resumes every stored server session on launch.
    func resumeIfPossible() async {
        guard accounts.isEmpty, !isResuming else { return }
        isResuming = true
        defer { isResuming = false }
        let stored = UserDefaults.standard.stringArray(forKey: "servers") ?? []
        for serverString in stored {
            guard let url = URL(string: serverString),
                  let credentials = KeychainStore.load(server: url) else { continue }
            let (client, cacheUnavailable) = makeClient(server: url)
            do {
                let profile = try await client.resume(credentials: credentials)
                await adopt(account: ServerAccount(
                    serverURL: url, client: client, cacheUnavailable: cacheUnavailable,
                    profile: profile, credentials: await client.credentials))
            } catch {
                // Token rejected or unreachable: drop the stored session.
                KeychainStore.delete(server: url)
            }
        }
        persistServerList()
        if let restored = UserDefaults.standard.string(forKey: "activeServer"),
           accounts.contains(where: { $0.id == restored }) {
            activeAccountId = restored
        } else {
            activeAccountId = accounts.first?.id
        }
    }

    func login(server: String, user: String, password: String) async {
        guard let url = URL(string: server), url.scheme?.hasPrefix("http") == true else {
            loginError = "Enter a valid server URL (https://…)"
            return
        }
        if let existing = accounts.first(where: { $0.id == url.host() }) {
            // Already signed in there — just switch.
            activeAccountId = existing.id
            showAddServer = false
            return
        }
        serverURLString = server
        loginError = nil
        loginFlow = .loggingIn
        let (client, cacheUnavailable) = makeClient(server: url)
        pendingLogin = (url, user, client, cacheUnavailable)
        do {
            let profile = try await client.login(user: user, password: password)
            await adopt(account: ServerAccount(
                serverURL: url, client: client, cacheUnavailable: cacheUnavailable,
                profile: profile, credentials: await client.credentials))
            finishLogin()
        } catch RocketChatError.twoFactorRequired(let challenge) {
            loginFlow = .twoFactor(challenge)
        } catch RocketChatError.notAuthenticated {
            loginError = "Invalid username or password."
            loginFlow = .idle
        } catch {
            loginError = friendlyMessage(error)
            loginFlow = .idle
        }
    }

    func submitTwoFactor(code: String, method: TwoFactorMethod) async {
        guard case .twoFactor(let challenge) = loginFlow,
              let pendingLogin else { return }
        do {
            let profile = try await pendingLogin.client.completeTwoFactorLogin(
                challenge, code: code, method: method)
            await adopt(account: ServerAccount(
                serverURL: pendingLogin.server, client: pendingLogin.client,
                cacheUnavailable: pendingLogin.cacheUnavailable,
                profile: profile,
                credentials: await pendingLogin.client.credentials))
            finishLogin()
        } catch RocketChatError.twoFactorInvalid(let fresh) {
            loginError = "Invalid code — try again."
            loginFlow = .twoFactor(fresh)
        } catch {
            loginError = friendlyMessage(error)
            loginFlow = .idle
        }
    }

    func resendEmailCode() async {
        guard let pendingLogin else { return }
        try? await pendingLogin.client.sendEmailCode(emailOrUsername: pendingLogin.user)
    }

    func cancelTwoFactor() {
        loginFlow = .idle
        loginError = nil
    }

    // MARK: - Account lifecycle

    /// Signs out of one workspace; remaining accounts stay live.
    func logout(accountId: String) async {
        guard let index = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        let account = accounts.remove(at: index)
        notifications.unregister(accountId: accountId)
        persistServerList()
        if activeAccountId == accountId {
            activeAccountId = accounts.first?.id
        }
        try? await account.client.logout()
        await account.client.stopSync()
        KeychainStore.delete(server: account.serverURL)
        // Cached history belongs to the session — remove it (and the SQLite
        // sidecar files) once the connections are released.
        if let cacheFile = account.client.cacheFileURL {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: URL(filePath: cacheFile.path(percentEncoded: false) + suffix))
            }
        }
    }

    /// Slow/fast polling for every live account follows app activation.
    func setAppActive(_ active: Bool) async {
        notifications.appActive = active
        for account in accounts {
            await account.client.setAppActive(active)
        }
    }

    // MARK: - Internals

    private func adopt(account: ServerAccount) async {
        if let credentials = account.credentials {
            KeychainStore.save(credentials, server: account.serverURL)
        }
        accounts.append(account)
        activeAccountId = account.id
        persistServerList()
        await account.client.startSync()
        await account.client.enablePushSignals()
        notifications.register(
            accountId: account.id, client: account.client,
            selfUserId: account.profile._id)
    }

    private func finishLogin() {
        loginFlow = .idle
        loginError = nil
        pendingLogin = nil
        showAddServer = false
    }

    private func persistServerList() {
        UserDefaults.standard.set(
            accounts.map(\.serverURL.absoluteString), forKey: "servers")
    }

    /// Per-host SQLite caches live in Application Support.
    private static var cacheDirectory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appending(path: "RocketNative")
    }

    /// SQLite-cached client; falls back to in-memory (with a visible warning)
    /// if the database can't open.
    private func makeClient(server: URL) -> (RocketChatClient, cacheUnavailable: Bool) {
        do {
            let client = try RocketChatClient(
                serverURL: server, cache: .sqlite(directory: Self.cacheDirectory))
            return (client, false)
        } catch {
            return (RocketChatClient(serverURL: server), true)
        }
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
