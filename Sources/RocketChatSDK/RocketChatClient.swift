import Foundation

/// Entry point for a single Rocket.Chat server connection.
///
/// Instance-based by design: create one client per server/workspace.
/// The SDK is REST-only — live updates are delivered by an adaptive
/// delta-sync poller, not the deprecated realtime (DDP) API.
public final class RocketChatClient: Sendable {
    public let serverURL: URL

    public init(serverURL: URL) {
        self.serverURL = serverURL
    }
}
