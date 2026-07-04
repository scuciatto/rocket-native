import Foundation

/// Injectable clock so rate-limit sleeps are testable.
protocol RESTClock: Sendable {
    var now: Date { get }
    func sleep(seconds: TimeInterval) async throws
}

struct SystemClock: RESTClock {
    var now: Date { Date() }
    func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// Tracks `x-ratelimit-*` headers per endpoint path and spaces out calls.
///
/// Rocket.Chat's default budget is small (historically ~10 calls / 60 s per
/// endpoint per connection), so the poller depends on this being accurate:
/// - pre-emptively waits when a path's budget is exhausted,
/// - on 429, waits until `x-ratelimit-reset` (epoch milliseconds).
actor RateLimiter {
    private struct PathState {
        var remaining: Int
        var reset: Date
    }

    private var states: [String: PathState] = [:]
    private let clock: RESTClock

    init(clock: RESTClock) {
        self.clock = clock
    }

    /// Delay to apply before calling `path`, if its budget is spent.
    func waitTime(for path: String) -> TimeInterval {
        guard let state = states[path], state.remaining <= 0 else { return 0 }
        return max(0, state.reset.timeIntervalSince(clock.now))
    }

    func record(path: String, response: HTTPURLResponse) {
        guard
            let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining")
                .flatMap(Int.init),
            let resetMillis = response.value(forHTTPHeaderField: "x-ratelimit-reset")
                .flatMap(Double.init)
        else { return }
        states[path] = PathState(
            remaining: remaining,
            reset: Date(timeIntervalSince1970: resetMillis / 1000))
    }

    /// Point at which a 429'd call may retry, from headers when present.
    func retryDate(for path: String, response: HTTPURLResponse) -> Date {
        if let resetMillis = response.value(forHTTPHeaderField: "x-ratelimit-reset")
            .flatMap(Double.init) {
            return Date(timeIntervalSince1970: resetMillis / 1000)
        }
        return clock.now.addingTimeInterval(5)
    }
}
