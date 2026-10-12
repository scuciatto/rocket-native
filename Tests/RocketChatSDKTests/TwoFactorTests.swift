import Testing
import Foundation
@testable import RocketChatSDK

private let serverURL = URL(string: "https://chat.example.com")!

private let loginRequiredJSON = """
{
  "success": false,
  "status": "error",
  "error": "totp-required",
  "message": "TOTP Required",
  "details": {
    "method": "totp",
    "codeGenerated": false,
    "availableMethods": ["totp", "email"],
    "emailOrUsername": "felipe"
  }
}
"""

private func restRequiredJSON(method: String = "totp") -> String {
    """
    {
      "success": false,
      "error": "TOTP Required",
      "errorType": "totp-required",
      "details": {"method": "\(method)", "codeGenerated": false,
                  "availableMethods": ["\(method)"]}
    }
    """
}

/// The server sends `totp-invalid` without details on some paths.
private let restInvalidJSON = """
{"success": false, "error": "TOTP Invalid", "errorType": "totp-invalid"}
"""

private let meJSON = #"{"_id": "uid-9", "username": "felipe", "success": true}"#

/// Scripted provider: hands out queued codes (nil = cancel) and records
/// every prompt and end-of-challenge call.
private actor RecordingProvider: TwoFactorCodeProvider {
    private var codes: [String?]
    private(set) var prompts: [TwoFactorChallenge] = []
    private(set) var ended: [TwoFactorChallenge] = []

    init(codes: [String?]) {
        self.codes = codes
    }

    func code(for challenge: TwoFactorChallenge) async -> String? {
        prompts.append(challenge)
        return codes.isEmpty ? nil : codes.removeFirst()
    }

    func challengeEnded(_ challenge: TwoFactorChallenge) async {
        ended.append(challenge)
    }
}

private func makeClient(_ transport: MockHTTPTransport) async -> RocketChatClient {
    let client = RocketChatClient(
        serverURL: serverURL, transport: transport, clock: TestClock())
    await client.adopt(credentials: AuthCredentials(authToken: "tok", userId: "uid-9"))
    return client
}

@Suite struct TwoFactorTests {
    // MARK: - Error envelopes

    @Test func loginUnauthorizedWithTOTPRequiredYieldsChallenge() async throws {
        let transport = MockHTTPTransport()
        transport.respond(status: 401, json: loginRequiredJSON)
        let client = RocketChatClient(
            serverURL: serverURL, transport: transport, clock: TestClock())

        do {
            _ = try await client.login(user: "felipe", password: "secret")
            Issue.record("Expected twoFactorRequired to be thrown")
        } catch let RocketChatError.twoFactorRequired(challenge) {
            #expect(challenge.method == .totp)
            #expect(challenge.availableMethods == [.totp, .email])
            #expect(challenge.emailOrUsername == "felipe")
            #expect(!challenge.emailCodeGenerated)
            #expect(!challenge.isRetry)
        }
    }

    @Test(arguments: [
        #"{"status": "error", "error": 403, "message": "User not found"}"#,
        #"{"status": "error", "error": "Unauthorized", "message": "Unauthorized"}"#,
    ])
    func loginUnauthorizedWithoutTwoFactorIsNotAuthenticated(body: String) async throws {
        let transport = MockHTTPTransport()
        transport.respond(status: 401, json: body)
        let client = RocketChatClient(
            serverURL: serverURL, transport: transport, clock: TestClock())

        do {
            _ = try await client.login(user: "felipe", password: "wrong")
            Issue.record("Expected notAuthenticated to be thrown")
        } catch RocketChatError.notAuthenticated {
            // expected
        }
    }

    @Test func invalidWithoutDetailsInheritsChallenge() async throws {
        let transport = MockHTTPTransport()
        transport.respond(status: 401, json: loginRequiredJSON)
        transport.respond(status: 401, json: #"{"status": "error", "error": "totp-invalid"}"#)
        let client = RocketChatClient(
            serverURL: serverURL, transport: transport, clock: TestClock())

        var original: TwoFactorChallenge?
        do {
            _ = try await client.login(user: "felipe", password: "secret")
        } catch let RocketChatError.twoFactorRequired(pending) {
            original = pending
        }
        let challenge = try #require(original)

        do {
            _ = try await client.completeTwoFactorLogin(challenge, code: "000000")
            Issue.record("Expected twoFactorInvalid to be thrown")
        } catch let RocketChatError.twoFactorInvalid(retry) {
            #expect(retry.id == challenge.id)
            #expect(retry.isRetry)
            #expect(retry.availableMethods == [.totp, .email])
            #expect(retry.method == .totp)
            #expect(retry.emailOrUsername == "felipe")
        }
    }

    @Test(arguments: [
        (400, #"{"success": false, "error": "Max attempts", "errorType": "totp-max-attempts"}"#),
        (401, #"{"status": "error", "error": "totp-max-attempts", "message": "Max attempts"}"#),
    ])
    func maxAttemptsIsHTTPError(status: Int, body: String) async throws {
        let transport = MockHTTPTransport()
        transport.respond(status: status, json: body)
        let client = await makeClient(transport)

        do {
            _ = try await client.me()
            Issue.record("Expected httpError to be thrown")
        } catch let RocketChatError.httpError(thrownStatus, errorType, _) {
            #expect(thrownStatus == status)
            #expect(errorType == "totp-max-attempts")
        }
    }

    // MARK: - Provider

    @Test func providerAnswersChallengeAndCallSucceeds() async throws {
        let transport = MockHTTPTransport()
        transport.respond(status: 400, json: restRequiredJSON())
        transport.expect { request in
            #expect(request.value(forHTTPHeaderField: "x-2fa-code") == "123456")
            #expect(request.value(forHTTPHeaderField: "x-2fa-method") == "totp")
            #expect(request.value(forHTTPHeaderField: "X-Auth-Token") == "tok")
            return (Data(meJSON.utf8),
                    MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }
        let client = await makeClient(transport)
        let provider = RecordingProvider(codes: ["123456"])
        await client.setTwoFactorProvider(provider)

        let me = try await client.me()

        #expect(me.username == "felipe")
        let prompts = await provider.prompts
        let ended = await provider.ended
        #expect(prompts.count == 1)
        #expect(ended.count == 1)
        #expect(ended.first?.id == prompts.first?.id)
    }

    @Test func wrongCodeRepromptsWithSameChallengeId() async throws {
        let transport = MockHTTPTransport()
        transport.respond(status: 400, json: restRequiredJSON())
        transport.respond(status: 400, json: restInvalidJSON)
        transport.expect { request in
            #expect(request.value(forHTTPHeaderField: "x-2fa-code") == "123456")
            return (Data(meJSON.utf8),
                    MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }
        let client = await makeClient(transport)
        let provider = RecordingProvider(codes: ["000000", "123456"])
        await client.setTwoFactorProvider(provider)

        _ = try await client.me()

        let prompts = await provider.prompts
        #expect(prompts.count == 2)
        #expect(prompts[0].isRetry == false)
        #expect(prompts[1].isRetry)
        #expect(prompts[1].id == prompts[0].id)
        #expect(prompts[1].method == .totp)
        #expect(await provider.ended.count == 1)
    }

    @Test func nilCodeCancelsWithoutReplay() async throws {
        let transport = MockHTTPTransport()
        transport.respond(status: 400, json: restRequiredJSON())
        let client = await makeClient(transport)
        let provider = RecordingProvider(codes: [nil])
        await client.setTwoFactorProvider(provider)

        do {
            _ = try await client.me()
            Issue.record("Expected cancelled to be thrown")
        } catch RocketChatError.cancelled {
            // expected
        }
        #expect(transport.requests.count == 1)
        #expect(await provider.ended.count == 1)
    }

    @Test func nonRetryableFailureStillEndsChallenge() async throws {
        let transport = MockHTTPTransport()
        transport.respond(status: 400, json: restRequiredJSON())
        transport.respond(status: 500, json: #"{"success": false, "error": "boom"}"#)
        let client = await makeClient(transport)
        let provider = RecordingProvider(codes: ["123456"])
        await client.setTwoFactorProvider(provider)

        await #expect(throws: RocketChatError.self) {
            try await client.me()
        }
        #expect(await provider.ended.count == 1)
    }

    @Test func withoutProviderChallengeIsThrown() async throws {
        let transport = MockHTTPTransport()
        transport.respond(status: 400, json: restRequiredJSON())
        let client = await makeClient(transport)

        do {
            _ = try await client.me()
            Issue.record("Expected twoFactorRequired to be thrown")
        } catch RocketChatError.twoFactorRequired {
            // backward compatible
        }
    }

    @Test func loginIgnoresProvider() async throws {
        let transport = MockHTTPTransport()
        transport.respond(status: 401, json: loginRequiredJSON)
        let client = RocketChatClient(
            serverURL: serverURL, transport: transport, clock: TestClock())
        let provider = RecordingProvider(codes: ["123456"])
        await client.setTwoFactorProvider(provider)

        do {
            _ = try await client.login(user: "felipe", password: "secret")
            Issue.record("Expected twoFactorRequired to be thrown")
        } catch RocketChatError.twoFactorRequired {
            // explicit login flow unchanged
        }
        #expect(await provider.prompts.isEmpty)
    }

    @Test func passwordMethodSendsSHA256Hex() async throws {
        let transport = MockHTTPTransport()
        transport.respond(status: 400, json: restRequiredJSON(method: "password"))
        transport.expect { request in
            #expect(request.value(forHTTPHeaderField: "x-2fa-code")
                == "2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b")
            #expect(request.value(forHTTPHeaderField: "x-2fa-method") == "password")
            return (Data(meJSON.utf8),
                    MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }
        let client = await makeClient(transport)
        await client.setTwoFactorProvider(RecordingProvider(codes: ["secret"]))

        _ = try await client.me()
    }

    @Test func replayHeadersDoNotLeakIntoLaterRequests() async throws {
        let transport = MockHTTPTransport()
        transport.respond(status: 400, json: restRequiredJSON())
        transport.respond(json: meJSON)
        transport.expect { request in
            #expect(request.value(forHTTPHeaderField: "x-2fa-code") == nil)
            #expect(request.value(forHTTPHeaderField: "x-2fa-method") == nil)
            return (Data(meJSON.utf8),
                    MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }
        let client = await makeClient(transport)
        await client.setTwoFactorProvider(RecordingProvider(codes: ["123456"]))

        _ = try await client.me()
        _ = try await client.me()
        #expect(transport.requests.count == 3)
    }

    // MARK: - Personal access tokens

    @Test func generatePersonalAccessToken() async throws {
        let transport = MockHTTPTransport()
        transport.expect { request in
            #expect(request.url?.path() == "/api/v1/users.generatePersonalAccessToken")
            #expect(request.httpMethod == "POST")
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
                as? [String: Any]
            #expect(body?["tokenName"] as? String == "ci")
            #expect(body?["bypassTwoFactor"] as? Bool == true)
            return (Data(#"{"token": "pat-secret", "success": true}"#.utf8),
                    MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }
        let client = await makeClient(transport)

        let token = try await client.generatePersonalAccessToken(
            name: "ci", bypassTwoFactor: true)
        #expect(token == "pat-secret")
    }

    @Test func removePersonalAccessToken() async throws {
        let transport = MockHTTPTransport()
        transport.expect { request in
            #expect(request.url?.path() == "/api/v1/users.removePersonalAccessToken")
            #expect(request.httpMethod == "POST")
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
                as? [String: Any]
            #expect(body?["tokenName"] as? String == "ci")
            #expect(body?.count == 1)
            return (Data(#"{"success": true}"#.utf8),
                    MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }
        let client = await makeClient(transport)

        try await client.removePersonalAccessToken(name: "ci")
    }
}
