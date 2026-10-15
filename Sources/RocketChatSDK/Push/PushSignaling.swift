import Foundation

/// A hint that server state changed. Signals carry **no data** — they only
/// tell the sync engine to run the corresponding REST delta tick now instead
/// of waiting for the next poll. REST remains the single source of truth.
public enum PushSignal: Sendable, Equatable {
    /// Activity in a specific room (new/edited message, etc.).
    case roomActivity(roomId: String)
    /// Something changed at the sidebar level (any room, unreads, membership).
    case sidebarChanged
    /// Transport health. While `true` the engine stretches its poll cadence
    /// to a safety net; `false` restores full polling.
    case connected(Bool)
}

/// The push seam: anything that can wake the sync engine. The engine treats
/// the transport as advisory — polling continues regardless (stretched while
/// the transport is healthy), so a broken transport degrades silently to the
/// plain polling behavior.
///
/// Implementations today: `StreamerSignalTransport` (opt-in; uses the
/// realtime streamer WebSocket as a change bell).
public protocol PushSignaling: Sendable {
    /// Starts the transport and returns its signal stream. The stream
    /// finishing means the transport stopped (engine reverts to polling).
    func signals() async -> AsyncStream<PushSignal>
    func stop() async
}
