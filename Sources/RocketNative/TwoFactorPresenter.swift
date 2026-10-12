import SwiftUI
import RocketChatSDK

/// Queues mid-session 2FA prompts from every account's client and drives one
/// `TwoFactorSheet` at a time (FIFO). The SDK's prompt-and-replay loop calls
/// in through `AccountTwoFactorProvider`; a retry of the same challenge
/// (same `id`) updates the visible sheet in place instead of queueing.
///
/// Callers of protected endpoints should treat `RocketChatError.cancelled`
/// as a silent no-op: it means the user dismissed this sheet.
@MainActor
@Observable
final class TwoFactorPresenter {
    struct Request: Identifiable {
        var challenge: TwoFactorChallenge
        let accountId: String
        let accountName: String
        var id: UUID { challenge.id }
    }

    /// The prompt on screen, if any.
    private(set) var current: Request?
    /// A submitted code is being verified; the sheet stays up with a spinner.
    private(set) var isVerifying = false
    /// Informational line for the current prompt (e.g. after a resend).
    var notice: String?

    private var queue: [Request] = []
    /// Waiting SDK calls, keyed by challenge id. Kept outside `Request` so
    /// observation doesn't track them.
    @ObservationIgnored
    private var continuations: [UUID: CheckedContinuation<String?, Never>] = [:]

    /// Asks the user for a code; suspends until submit or cancel.
    func code(
        for challenge: TwoFactorChallenge, accountId: String, accountName: String
    ) async -> String? {
        await withCheckedContinuation { continuation in
            // A stale waiter for this challenge can't exist in practice;
            // release it rather than leak it.
            continuations.updateValue(continuation, forKey: challenge.id)?.resume(returning: nil)
            if current?.id == challenge.id {
                current?.challenge = challenge
                isVerifying = false
                notice = nil
            } else if let index = queue.firstIndex(where: { $0.id == challenge.id }) {
                queue[index].challenge = challenge
            } else {
                queue.append(Request(
                    challenge: challenge, accountId: accountId, accountName: accountName))
                if current == nil { advance() }
            }
        }
    }

    /// The SDK finished with this challenge (accepted, cancelled or failed).
    func challengeEnded(_ id: UUID) {
        continuations.removeValue(forKey: id)?.resume(returning: nil)
        if current?.id == id {
            advance()
        } else {
            queue.removeAll { $0.id == id }
        }
    }

    func submit(code: String) {
        guard let current, let continuation = continuations.removeValue(forKey: current.id)
        else { return }
        isVerifying = true
        notice = nil
        continuation.resume(returning: code)
    }

    /// Dismisses the current prompt; its call throws `.cancelled`.
    func cancel() {
        guard let current else { return }
        continuations.removeValue(forKey: current.id)?.resume(returning: nil)
        advance()
    }

    /// Drops every prompt for a signed-out account.
    func cancelAll(accountId: String) {
        for request in queue where request.accountId == accountId {
            continuations.removeValue(forKey: request.id)?.resume(returning: nil)
        }
        queue.removeAll { $0.accountId == accountId }
        if current?.accountId == accountId { cancel() }
    }

    private func advance() {
        current = queue.isEmpty ? nil : queue.removeFirst()
        isVerifying = false
        notice = nil
    }
}

/// Per-account bridge from the SDK's provider protocol to the shared
/// presenter. Holds no client, so client → provider → presenter can't cycle.
struct AccountTwoFactorProvider: TwoFactorCodeProvider {
    let accountId: String
    let accountName: String
    let presenter: TwoFactorPresenter

    func code(for challenge: TwoFactorChallenge) async -> String? {
        await presenter.code(for: challenge, accountId: accountId, accountName: accountName)
    }

    func challengeEnded(_ challenge: TwoFactorChallenge) async {
        await presenter.challengeEnded(challenge.id)
    }
}
