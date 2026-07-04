import Foundation
import RocketChatSDK

// rc-cli — smoke tool for RocketChatSDK. Sessions are stored as plain JSON in
// ~/.config/rc-cli/session.json; this is a developer tool, not the app
// (the app stores credentials in the Keychain).

struct CLISession: Codable {
    var serverURL: URL
    var authToken: String
    var userId: String
    var username: String?
}

let sessionFile = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".config/rc-cli/session.json")

func saveSession(_ session: CLISession) throws {
    try FileManager.default.createDirectory(
        at: sessionFile.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(session)
    try data.write(to: sessionFile, options: [.atomic])
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: sessionFile.path())
}

func loadSession() -> CLISession? {
    guard let data = try? Data(contentsOf: sessionFile) else { return nil }
    return try? JSONDecoder().decode(CLISession.self, from: data)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func promptLine(_ prompt: String) -> String {
    print(prompt, terminator: "")
    return readLine() ?? ""
}

func promptPassword(_ prompt: String) -> String {
    guard let raw = getpass(prompt) else { return "" }
    return String(cString: raw)
}

func authenticatedClient() async -> (RocketChatClient, CLISession) {
    guard let session = loadSession() else {
        fail("no session — run `rc-cli login <server-url> <username>` first")
    }
    let client = RocketChatClient(serverURL: session.serverURL)
    await client.adopt(credentials: AuthCredentials(
        authToken: session.authToken, userId: session.userId))
    return (client, session)
}

func describe(_ error: Error) -> String {
    guard let rcError = error as? RocketChatError else { return "\(error)" }
    switch rcError {
    case .network(let underlying):
        return "network failure: \(underlying.localizedDescription)"
    case .httpError(let status, let type, let message):
        return "HTTP \(status) \(type ?? "") \(message ?? "")"
    case .notAuthenticated:
        return "not authenticated — token may have expired; run `rc-cli login` again"
    case .rateLimited(let retryAfter):
        return "rate limited (retry after \(retryAfter.map(String.init(describing:)) ?? "?"))"
    default:
        return "\(rcError)"
    }
}

func runLogin(server: String, user: String) async {
    guard let url = URL(string: server), url.scheme?.hasPrefix("http") == true else {
        fail("invalid server URL: \(server)")
    }
    let client = RocketChatClient(serverURL: url)
    let password = ProcessInfo.processInfo.environment["RC_PASSWORD"]
        ?? promptPassword("Password: ")

    var profile: UserProfile
    do {
        profile = try await client.login(user: user, password: password)
    } catch RocketChatError.twoFactorRequired(var challenge) {
        print("Two-factor authentication required.")
        if challenge.emailCodeGenerated {
            print("A code was sent to your email address.")
        }
        while true {
            let method = challenge.defaultMethod
                ?? challenge.availableMethods.first ?? .totp
            let code = promptLine("2FA code (\(method.rawValue)): ")
                .trimmingCharacters(in: .whitespaces)
            do {
                profile = try await client.completeTwoFactorLogin(
                    challenge, code: code, method: method)
                break
            } catch RocketChatError.twoFactorInvalid(let fresh) {
                print("Invalid code, try again.")
                challenge = fresh
            } catch {
                fail(describe(error))
            }
        }
    } catch RocketChatError.notAuthenticated {
        fail("invalid username or password")
    } catch {
        fail(describe(error))
    }

    guard let credentials = await client.credentials else {
        fail("login succeeded but no credentials were stored")
    }
    do {
        try saveSession(CLISession(
            serverURL: url, authToken: credentials.authToken,
            userId: credentials.userId, username: profile.username))
    } catch {
        fail("could not save session: \(error)")
    }
    print("Logged in as \(profile.username ?? profile._id) on \(url.host() ?? server)")
}

func runMe() async {
    let (client, _) = await authenticatedClient()
    do {
        let me = try await client.me()
        print("id:       \(me._id)")
        print("username: \(me.username ?? "-")")
        print("name:     \(me.name ?? "-")")
        print("status:   \(me.status ?? "-")")
        print("roles:    \(me.roles?.joined(separator: ", ") ?? "-")")
    } catch {
        fail(describe(error))
    }
}

func runLogout() async {
    let (client, _) = await authenticatedClient()
    try? await client.logout()
    try? FileManager.default.removeItem(at: sessionFile)
    print("Logged out.")
}

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "login":
    guard arguments.count == 3 else {
        fail("usage: rc-cli login <server-url> <username>")
    }
    await runLogin(server: arguments[1], user: arguments[2])
case "me":
    await runMe()
case "logout":
    await runLogout()
default:
    print("""
    rc-cli — Rocket.Chat SDK smoke tool

    Usage:
      rc-cli login <server-url> <username>   Log in (supports 2FA)
      rc-cli me                              Show the authenticated user
      rc-cli logout                          Invalidate and forget the session

    Coming as SDK phases land: rooms, history, send, tail, search, spotlight
    """)
    exit(arguments.isEmpty ? 0 : 1)
}
