import Foundation

/// One event from the realtime streamer. Payload events are applied to the
/// stores immediately; REST delta sync stays the source of truth and
/// converges anything the socket missed or got wrong.
public enum RealtimeEvent: Sendable, Equatable {
    /// Transport health. While `true` the engine stretches its poll cadence
    /// to a safety net; `false` restores full polling.
    case connected(Bool)

    // Room payloads (`stream-room-messages`, `stream-notify-room`)
    /// A new or updated message (edits, reactions and thread counters arrive
    /// as updates of the same record).
    case message(roomId: String, Message)
    case messageDeleted(roomId: String, messageId: String)
    /// A watched room's message stream became ready (`true`) or was lost.
    /// While live, the room needs no REST tick per message.
    case roomLive(roomId: String, Bool)
    /// Typing start/stop from `<rid>/user-activity`. `username` is the
    /// display name when the server's `UI_Use_Real_Name` is on.
    case typing(roomId: String, threadId: String?, username: String, active: Bool)

    // User-level payloads (`stream-notify-user`, `stream-user-presence`)
    case presence(UserPresence)
    case subscriptionChanged(Subscription)
    case subscriptionRemoved(roomId: String)
    case roomChanged(Room)
    case roomRemoved(roomId: String)

    // Bell fallbacks: a payload that doesn't decode degrades to a REST tick
    // instead of being dropped.
    /// Activity in a specific room; the engine ticks it if it's open and its
    /// message stream isn't live.
    case roomActivity(roomId: String)
    /// Something changed at the sidebar level; the engine runs a sidebar tick.
    case sidebarChanged
}

/// The realtime seam: anything that streams `RealtimeEvent`s and accepts
/// subscription changes. The engine treats it as an accelerator — polling
/// continues regardless (stretched while the transport is healthy), so a
/// broken transport degrades silently to plain polling.
///
/// Implementation: `StreamerTransport` (the server's DDP streamer socket).
public protocol RealtimeTransport: Sendable {
    /// Starts the transport and returns its event stream. The stream
    /// finishing means the transport stopped (engine reverts to polling).
    func events() async -> AsyncStream<RealtimeEvent>
    func stop() async

    /// Adds/removes a room's message, delete and typing subscriptions. The
    /// desired set survives reconnects.
    func watchRoom(_ roomId: String) async
    func unwatchRoom(_ roomId: String) async

    /// Adds/removes users whose presence changes should be streamed.
    func watchPresence(added: [String], removed: [String]) async

    /// Broadcasts our typing state in a room (optionally a thread). `name`
    /// must match what the server expects: username, or display name when
    /// `UI_Use_Real_Name` is on. Dropped silently while disconnected.
    func sendTyping(roomId: String, threadId: String?, name: String, active: Bool) async
}
