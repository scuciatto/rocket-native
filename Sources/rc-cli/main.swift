import Foundation
import RocketChatSDK

// rc-cli — smoke tool for RocketChatSDK. Sessions are stored as plain JSON in
// ~/.config/rc-cli/session.json; this is a developer tool, not the app
// (the app stores credentials in the Keychain).

// Line-buffer stdout so `tail` output streams when piped/redirected.
setlinebuf(stdout)

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

/// Answers mid-session 2FA challenges on stdin. The password method reads
/// without echo; for email, `r` asks the server to resend the code.
struct CLITwoFactorProvider: TwoFactorCodeProvider {
    let client: @Sendable () -> RocketChatClient?
    let username: String?

    func code(for challenge: TwoFactorChallenge) async -> String? {
        if challenge.isRetry {
            print(challenge.method == .password
                ? "Incorrect password, try again." : "Invalid code, try again.")
        } else {
            print("Two-factor authentication required.")
            if challenge.method == .email, challenge.emailCodeGenerated {
                print("A code was sent to your email address.")
            }
        }
        while true {
            let code: String
            switch challenge.method {
            case .password:
                code = promptPassword("Password: ")
            case .email:
                code = promptLine("2FA code (email, r to resend): ")
                    .trimmingCharacters(in: .whitespaces)
                if code == "r" {
                    await resend(challenge)
                    continue
                }
            case .totp:
                code = promptLine("2FA code (totp): ").trimmingCharacters(in: .whitespaces)
            }
            // Empty input (or EOF) cancels the call.
            return code.isEmpty ? nil : code
        }
    }

    private func resend(_ challenge: TwoFactorChallenge) async {
        guard let identity = challenge.emailOrUsername ?? username,
              let client = client() else {
            print("Cannot resend: unknown username.")
            return
        }
        do {
            try await client.sendEmailCode(emailOrUsername: identity)
            print("Code sent! Please check your email.")
        } catch {
            print("Resend failed: \(describe(error))")
        }
    }
}

func authenticatedClient() async -> (RocketChatClient, CLISession) {
    guard let session = loadSession() else {
        fail("no session — run `rc-cli login <server-url> <username>` first")
    }
    // RC_CACHE_DIR opts into the SQLite offline cache (also smoke-tests it).
    let client: RocketChatClient
    if let cacheDir = ProcessInfo.processInfo.environment["RC_CACHE_DIR"] {
        do {
            client = try RocketChatClient(
                serverURL: session.serverURL,
                cache: .sqlite(directory: URL(filePath: cacheDir, directoryHint: .isDirectory)))
        } catch {
            fail("could not open cache in \(cacheDir): \(error)")
        }
    } else {
        client = RocketChatClient(serverURL: session.serverURL)
    }
    await client.adopt(credentials: AuthCredentials(
        authToken: session.authToken, userId: session.userId))
    // Weak: the provider lives inside the client, so a strong reference
    // would make a cycle.
    weak let weakClient = client
    await client.setTwoFactorProvider(CLITwoFactorProvider(
        client: { weakClient }, username: session.username))
    return (client, session)
}

func describe(_ error: Error) -> String {
    guard let rcError = error as? RocketChatError else { return "\(error)" }
    switch rcError {
    case .network(let underlying):
        return "network failure: \(underlying.localizedDescription)"
    case .httpError(_, "totp-max-attempts", _):
        return "too many invalid 2FA codes — start over"
    case .cancelled:
        return "cancelled"
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
            // The server verifies login codes with its first active method.
            let method = challenge.method
            let code = promptLine(method == .email
                ? "2FA code (email, r to resend): " : "2FA code (\(method.rawValue)): ")
                .trimmingCharacters(in: .whitespaces)
            if method == .email, code == "r" {
                do {
                    try await client.sendEmailCode(
                        emailOrUsername: challenge.emailOrUsername ?? user)
                    print("Code sent! Please check your email.")
                } catch {
                    print("Resend failed: \(describe(error))")
                }
                continue
            }
            do {
                profile = try await client.completeTwoFactorLogin(challenge, code: code)
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

func resolveRoom(_ client: RocketChatClient, _ nameOrId: String) async -> RoomSummary {
    do {
        let rooms = try await client.rooms()
        if let match = rooms.first(where: {
            $0.id == nameOrId || $0.displayName.lowercased() == nameOrId.lowercased()
        }) {
            return match
        }
        fail("no joined room named '\(nameOrId)'")
    } catch {
        fail(describe(error))
    }
}

func timestamp(_ date: Date?) -> String {
    guard let date else { return "----------------" }
    return date.formatted(.iso8601.year().month().day()
        .dateTimeSeparator(.space).time(includingFractionalSeconds: false))
}

func printMessage(_ message: Message) {
    let author = message.u.username ?? message.u._id
    if let system = message.t {
        print("\(timestamp(message.ts))  -- [\(system)] \(author) \(message.msg)")
    } else {
        let thread = message.tmid.map { " (thread \($0))" } ?? ""
        print("\(timestamp(message.ts))  <\(author)>\(thread) \(message.msg)")
    }
}

func runRooms() async {
    let (client, _) = await authenticatedClient()
    do {
        let rooms = try await client.rooms()
        let typeLabel: [RoomType: String] = [
            .channel: "#", .privateGroup: "🔒", .directMessage: "@", .livechat: "L",
        ]
        for room in rooms where room.open {
            let badge = room.unread > 0 ? " [\(room.unread)]" : ""
            let mentions = room.mentions > 0 ? " @\(room.mentions)" : ""
            let last = room.lastMessage.map {
                " — \($0.u.username ?? "?"): \($0.msg.prefix(48))"
            } ?? ""
            print("\(typeLabel[room.type] ?? "?") \(room.displayName)\(badge)\(mentions)\(last)")
        }
    } catch {
        fail(describe(error))
    }
}

func runHistory(room nameOrId: String, count: Int) async {
    let (client, _) = await authenticatedClient()
    let room = await resolveRoom(client, nameOrId)
    do {
        let messages = try await client.history(
            roomId: room.id, type: room.type, count: count)
        for message in messages.reversed() {
            printMessage(message)
        }
    } catch {
        fail(describe(error))
    }
}

func runSend(room nameOrId: String, text: String) async {
    let (client, _) = await authenticatedClient()
    let room = await resolveRoom(client, nameOrId)
    do {
        let sent = try await client.send(text: text, roomId: room.id)
        print("sent \(sent._id) to \(room.displayName)")
    } catch {
        fail(describe(error))
    }
}

func runTail(room nameOrId: String) async {
    let (client, _) = await authenticatedClient()
    await client.startSync()
    // RC_PUSH=1 enables the push bell: instant wake-ups, polling as safety net.
    if ProcessInfo.processInfo.environment["RC_PUSH"] == "1" {
        await client.enablePushSignals()
        print("(push signals enabled)")
    }
    let room = await resolveRoom(client, nameOrId)
    do {
        let handle = try await client.openRoom(room.id)
        print("Tailing \(room.displayName) — Ctrl-C to stop")
        var printedIds = Set<String>()
        for await snapshot in await handle.timelineUpdates() {
            for entry in snapshot.entries where !printedIds.contains(entry.id) {
                printedIds.insert(entry.id)
                printMessage(entry.message)
            }
        }
    } catch {
        fail(describe(error))
    }
}

func runThreads(room nameOrId: String) async {
    let (client, _) = await authenticatedClient()
    let room = await resolveRoom(client, nameOrId)
    do {
        let threads = try await client.threads(in: room.id)
        for thread in threads {
            let replies = thread.tcount ?? 0
            let last = thread.tlm.map(timestamp) ?? "?"
            print("\(thread._id)  [\(replies) replies, last \(last)] "
                + "<\(thread.u.username ?? "?")> \(thread.msg.prefix(60))")
        }
        if threads.isEmpty { print("no threads in \(room.displayName)") }
    } catch {
        fail(describe(error))
    }
}

func runSearch(room nameOrId: String, text: String) async {
    let (client, _) = await authenticatedClient()
    let room = await resolveRoom(client, nameOrId)
    do {
        let hits = try await client.searchMessages(in: room.id, text: text)
        for message in hits.reversed() {
            printMessage(message)
        }
        if hits.isEmpty { print("no matches") }
    } catch {
        fail(describe(error))
    }
}

func runSpotlight(query: String) async {
    let (client, _) = await authenticatedClient()
    do {
        let result = try await client.spotlight(query)
        for user in result.users {
            print("@\(user.username ?? "?")  \(user.name ?? "")  [\(user.status ?? "unknown")]")
        }
        for room in result.rooms {
            print("#\(room.name ?? room._id)")
        }
        if result.users.isEmpty && result.rooms.isEmpty { print("no matches") }
    } catch {
        fail(describe(error))
    }
}

func runDirectory(text: String, type: DirectoryType) async {
    let (client, _) = await authenticatedClient()
    do {
        let page = try await client.directory(text: text, type: type)
        for entry in page.items {
            switch type {
            case .users:
                print("@\(entry.username ?? "?")  \(entry.name ?? "")")
            case .channels, .teams:
                print("#\(entry.name ?? "?")  (\(entry.usersCount ?? 0) members)  \(entry.topic ?? "")")
            }
        }
        print("— \(page.items.count) of \(page.total)")
    } catch {
        fail(describe(error))
    }
}

func runUpload(room nameOrId: String, path: String, text: String?) async {
    let (client, _) = await authenticatedClient()
    let room = await resolveRoom(client, nameOrId)
    let url = URL(filePath: path)
    guard let data = try? Data(contentsOf: url) else {
        fail("could not read \(path)")
    }
    let file = UploadableFile(
        data: data, filename: url.lastPathComponent,
        mimeType: "application/octet-stream")
    do {
        let message = try await client.uploadFile(
            file, roomId: room.id, text: text)
        print("uploaded \(file.filename) to \(room.displayName)"
            + (message.map { " (message \($0._id))" } ?? ""))
    } catch {
        fail(describe(error))
    }
}

func runPATCreate(name: String) async {
    let (client, _) = await authenticatedClient()
    do {
        let token = try await client.generatePersonalAccessToken(name: name)
        print("token:   \(token)")
        print("user id: \(await client.credentials?.userId ?? "-")")
    } catch {
        fail(describe(error))
    }
}

func runPATRemove(name: String) async {
    let (client, _) = await authenticatedClient()
    do {
        try await client.removePersonalAccessToken(name: name)
        print("Removed token \"\(name)\".")
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
case "rooms":
    await runRooms()
case "history":
    guard arguments.count >= 2 else { fail("usage: rc-cli history <room> [count]") }
    await runHistory(room: arguments[1], count: arguments.count > 2 ? Int(arguments[2]) ?? 20 : 20)
case "send":
    guard arguments.count >= 3 else { fail("usage: rc-cli send <room> <text...>") }
    await runSend(room: arguments[1], text: arguments.dropFirst(2).joined(separator: " "))
case "tail":
    guard arguments.count == 2 else { fail("usage: rc-cli tail <room>") }
    await runTail(room: arguments[1])
case "upload":
    guard arguments.count >= 3 else { fail("usage: rc-cli upload <room> <path> [text...]") }
    await runUpload(
        room: arguments[1], path: arguments[2],
        text: arguments.count > 3 ? arguments.dropFirst(3).joined(separator: " ") : nil)
case "threads":
    guard arguments.count == 2 else { fail("usage: rc-cli threads <room>") }
    await runThreads(room: arguments[1])
case "search":
    guard arguments.count >= 3 else { fail("usage: rc-cli search <room> <text...>") }
    await runSearch(room: arguments[1], text: arguments.dropFirst(2).joined(separator: " "))
case "spotlight":
    guard arguments.count >= 2 else { fail("usage: rc-cli spotlight <query...>") }
    await runSpotlight(query: arguments.dropFirst().joined(separator: " "))
case "directory":
    guard arguments.count >= 2 else { fail("usage: rc-cli directory <text> [users|channels|teams]") }
    let type = arguments.count > 2
        ? DirectoryType(rawValue: arguments[2]) ?? .channels : .channels
    await runDirectory(text: arguments[1], type: type)
case "pat":
    let usage = "usage: rc-cli pat create|remove <name>"
    guard arguments.count == 3 else { fail(usage) }
    switch arguments[1] {
    case "create": await runPATCreate(name: arguments[2])
    case "remove": await runPATRemove(name: arguments[2])
    default: fail(usage)
    }
default:
    print("""
    rc-cli — Rocket.Chat SDK smoke tool

    Usage:
      rc-cli login <server-url> <username>     Log in (supports 2FA)
      rc-cli me                                Show the authenticated user
      rc-cli rooms                             List joined rooms with unread state
      rc-cli history <room> [count]            Show recent messages (default 20)
      rc-cli send <room> <text...>             Send a message
      rc-cli tail <room>                       Follow a room live (delta polling)
      rc-cli threads <room>                    List threads in a room
      rc-cli search <room> <text...>           Search messages in a room
      rc-cli spotlight <query...>              Global user/channel search
      rc-cli directory <text> [users|channels|teams]
      rc-cli pat create <name>                 Create a personal access token (2FA)
      rc-cli pat remove <name>                 Revoke a personal access token (2FA)
      rc-cli logout                            Invalidate and forget the session
    """)
    exit(arguments.isEmpty ? 0 : 1)
}
