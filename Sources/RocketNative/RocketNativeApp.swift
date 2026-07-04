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
            // Idle apps poll slower; activation triggers a catch-up tick.
            guard let client = session.client else { return }
            Task { await client.setAppActive(phase == .active) }
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Log Out") {
                    Task { await session.logout() }
                }
                .disabled(session.client == nil)
            }
        }
    }
}

struct RootView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        switch session.phase {
        case .active:
            MainWindow()
        default:
            LoginView()
        }
    }
}
