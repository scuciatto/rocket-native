import Testing
import Foundation
@testable import RocketChatSDK
@testable import RocketNative

private func makeChallenge(
    id: UUID = UUID(), isRetry: Bool = false
) -> TwoFactorChallenge {
    TwoFactorChallenge(
        id: id, availableMethods: [.totp], defaultMethod: .totp,
        emailCodeGenerated: false, emailOrUsername: nil, isRetry: isRetry,
        request: URLRequest(url: URL(string: "https://chat.example.com/api/v1/me")!),
        endpointPath: "me")
}

/// Lets the presenter's queued continuation register before the test acts.
@MainActor
private func settle() async {
    for _ in 0..<5 { await Task.yield() }
}

@MainActor
@Suite struct TwoFactorPresenterTests {
    @Test func requestsAreShownInFIFOOrder() async {
        let presenter = TwoFactorPresenter()
        let pending = [makeChallenge(), makeChallenge()]
        let (first, second) = (pending[0], pending[1])

        async let firstCode = presenter.code(for: first, accountId: "a", accountName: "A")
        await settle()
        async let secondCode = presenter.code(for: second, accountId: "b", accountName: "B")
        await settle()

        #expect(presenter.current?.id == first.id)
        presenter.submit(code: "111111")
        #expect(presenter.isVerifying)
        #expect(await firstCode == "111111")

        // The sheet stays up until the SDK reports the challenge ended.
        #expect(presenter.current?.id == first.id)
        presenter.challengeEnded(first.id)
        #expect(presenter.current?.id == second.id)
        #expect(presenter.current?.accountName == "B")
        #expect(!presenter.isVerifying)

        presenter.submit(code: "222222")
        #expect(await secondCode == "222222")
        presenter.challengeEnded(second.id)
        #expect(presenter.current == nil)
    }

    @Test func retryUpdatesCurrentInPlace() async {
        let presenter = TwoFactorPresenter()
        let original = makeChallenge()

        async let firstCode = presenter.code(for: original, accountId: "a", accountName: "A")
        await settle()
        presenter.submit(code: "000000")
        #expect(await firstCode == "000000")

        // Same id, as the SDK's retry challenge carries.
        let retry = makeChallenge(id: original.id, isRetry: true)
        async let secondCode = presenter.code(for: retry, accountId: "a", accountName: "A")
        await settle()

        #expect(presenter.current?.id == original.id)
        #expect(presenter.current?.challenge.isRetry == true)
        #expect(!presenter.isVerifying)
        presenter.submit(code: "123456")
        #expect(await secondCode == "123456")
    }

    @Test func challengeEndedForQueuedRequestDropsIt() async {
        let presenter = TwoFactorPresenter()
        let pending = [makeChallenge(), makeChallenge()]

        async let firstCode = presenter.code(for: pending[0], accountId: "a", accountName: "A")
        await settle()
        async let secondCode = presenter.code(for: pending[1], accountId: "a", accountName: "A")
        await settle()

        presenter.challengeEnded(pending[1].id)
        #expect(await secondCode == nil)
        presenter.cancel()
        #expect(await firstCode == nil)
        #expect(presenter.current == nil)
    }

    @Test func cancelResumesNilAndAdvances() async {
        let presenter = TwoFactorPresenter()
        let pending = [makeChallenge(), makeChallenge()]

        async let firstCode = presenter.code(for: pending[0], accountId: "a", accountName: "A")
        await settle()
        async let secondCode = presenter.code(for: pending[1], accountId: "b", accountName: "B")
        await settle()

        presenter.cancel()
        #expect(await firstCode == nil)
        #expect(presenter.current?.id == pending[1].id)

        // The SDK's late end-of-challenge call for the cancelled one is a no-op.
        presenter.challengeEnded(pending[0].id)
        #expect(presenter.current?.id == pending[1].id)

        presenter.cancel()
        #expect(await secondCode == nil)
        #expect(presenter.current == nil)
    }
}
