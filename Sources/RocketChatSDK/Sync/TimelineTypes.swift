import Foundation

public enum DeliveryState: Sendable, Equatable {
    /// Confirmed by the server.
    case sent
    /// Optimistically inserted; awaiting the server echo.
    case sending
    /// The send failed; the caller may retry or discard.
    case failed
}

public struct TimelineEntry: Sendable, Identifiable, Equatable {
    public var message: Message
    public var delivery: DeliveryState
    public var id: String { message._id }
}

/// Immutable view of one room's message window, oldest first.
public struct TimelineSnapshot: Sendable, Equatable {
    public var roomId: String
    public var entries: [TimelineEntry]
}

/// Health of the polling loops, for a status indicator in the UI.
public enum SyncState: Sendable, Equatable {
    case idle
    case syncing
    case synced
    /// Ticks are failing (network trouble); polling continues.
    case degraded
    /// The token was rejected; the user must log in again.
    case unauthorized
}
