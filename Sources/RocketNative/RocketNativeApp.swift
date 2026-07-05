import SwiftUI

@main
struct RocketNativeApp: App {
    @State private var session = AppSession()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Capped shared cache keeps avatar/image memory bounded.
        URLCache.shared = URLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: 50 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .task { await session.resumeIfPossible() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Idle apps poll slower (every live workspace); activation
            // triggers catch-up ticks. Notification suppression tracks the
            // same signal.
            Task { await session.setAppActive(phase == .active) }
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Add Server…") {
                    session.showAddServer = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(session.accounts.isEmpty)

                if let account = session.activeAccount {
                    Button("Log Out of \(account.displayName)") {
                        Task { await session.logout(accountId: account.id) }
                    }
                }
            }
        }
    }
}

struct RootView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        if !session.accounts.isEmpty {
            MainWindow()
        } else if session.isResuming {
            ProgressView("Connecting…")
                .frame(minWidth: 480, minHeight: 420)
        } else {
            LoginView()
        }
    }
}
