import Testing
import Foundation
@testable import RocketChatSDK

private let serverURL = URL(string: "https://chat.example.com")!

private let loginSuccessJSON = """
{
  "status": "success",
  "data": {
    "authToken": "tok-123",
    "userId": "uid-9",
    "me": {
      "_id": "uid-9",
      "username": "felipe",
      "name": "Felipe",
      "emails": [{"address": "felipe@example.com", "verified": true}],
      "roles": ["user"],
      "active": true
    }
  }
}
"""

private let totpRequiredJSON = """
{
  "success": false,
  "error": "TOTP Required [totp-required]",
  "errorType": "totp-required",
  "details": {
    "method": "totp",
    "codeGenerated": false,
    "availableMethods": ["totp", "email"]
  }
}
"""

@Suite struct AuthTests {
    @Test func loginStoresCredentialsAndReturnsProfile() async throws {
        let transport = MockHTTPTransport()
        transport.expect { request in
            #expect(request.url?.path() == "/api/v1/login")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "X-Auth-Token") == nil)
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
                as? [String: String]
            #expect(body?["user"] == "felipe")
            #expect(body?["password"] == "secret")
            return (Data(loginSuccessJSON.utf8),
                    MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }

        let client = RocketChatClient(
            serverURL: serverURL, transport: transport, clock: TestClock())
        let profile = try await client.login(user: "felipe", password: "secret")

        #expect(profile.username == "felipe")
        let credentials = await client.credentials
        #expect(credentials == AuthCredentials(authToken: "tok-123", userId: "uid-9"))
    }

    @Test func authHeadersAttachedToAuthenticatedCalls() async throws {
        let transport = MockHTTPTransport()
        transport.respond(json: loginSuccessJSON)
        transport.expect { request in
            #expect(request.value(forHTTPHeaderField: "X-Auth-Token") == "tok-123")
            #expect(request.value(forHTTPHeaderField: "X-User-Id") == "uid-9")
            return (Data(#"{"_id": "uid-9", "username": "felipe", "success": true}"#.utf8),
                    MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }

        let client = RocketChatClient(
            serverURL: serverURL, transport: transport, clock: TestClock())
        try await client.login(user: "felipe", password: "secret")
        let me = try await client.me()
        #expect(me._id == "uid-9")
    }

    @Test func callWithoutCredentialsThrowsNotAuthenticated() async throws {
        let client = RocketChatClient(
            serverURL: serverURL, transport: MockHTTPTransport(), clock: TestClock())
        await #expect(throws: RocketChatError.self) {
            try await client.me()
        }
    }

    @Test func twoFactorChallengeSurfacesAndReplayCompletesLogin() async throws {
        let transport = MockHTTPTransport()
        transport.respond(status: 400, json: totpRequiredJSON)
        transport.expect { request in
            #expect(request.value(forHTTPHeaderField: "x-2fa-code") == "123456")
            #expect(request.value(forHTTPHeaderField: "x-2fa-method") == "totp")
            #expect(request.url?.path() == "/api/v1/login")
            return (Data(loginSuccessJSON.utf8),
                    MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }

        let client = RocketChatClient(
            serverURL: serverURL, transport: transport, clock: TestClock())

        let challenge: TwoFactorChallenge
        do {
            _ = try await client.login(user: "felipe", password: "secret")
            Issue.record("Expected twoFactorRequired to be thrown")
            return
        } catch let RocketChatError.twoFactorRequired(pending) {
            challenge = pending
        }

        #expect(challenge.availableMethods == [.totp, .email])
        #expect(challenge.defaultMethod == .totp)

        let profile = try await client.completeTwoFactorLogin(
            challenge, code: "123456", method: .totp)
        #expect(profile.username == "felipe")
        let credentials = await client.credentials
        #expect(credentials?.authToken == "tok-123")
    }

    @Test func wrongTwoFactorCodeThrowsInvalidWithRetryableChallenge() async throws {
        let transport = MockHTTPTransport()
        transport.respond(status: 400, json: totpRequiredJSON)
        transport.respond(status: 400, json: """
            {"success": false, "error": "TOTP Invalid [totp-invalid]",
             "errorType": "totp-invalid"}
            """)

        let client = RocketChatClient(
            serverURL: serverURL, transport: transport, clock: TestClock())

        var challenge: TwoFactorChallenge?
        do {
            _ = try await client.login(user: "felipe", password: "secret")
        } catch let RocketChatError.twoFactorRequired(pending) {
            challenge = pending
        }

        do {
            _ = try await client.completeTwoFactorLogin(
                try #require(challenge), code: "000000", method: .totp)
            Issue.record("Expected twoFactorInvalid to be thrown")
        } catch RocketChatError.twoFactorInvalid {
            // expected — carries a fresh challenge for retry
        }
    }

    @Test func resumeRefreshesToken() async throws {
        let transport = MockHTTPTransport()
        transport.expect { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
                as? [String: String]
            #expect(body?["resume"] == "old-token")
            return (Data(loginSuccessJSON.utf8),
                    MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }

        let client = RocketChatClient(
            serverURL: serverURL, transport: transport, clock: TestClock())
        try await client.resume(
            credentials: AuthCredentials(authToken: "old-token", userId: "uid-9"))
        let credentials = await client.credentials
        #expect(credentials?.authToken == "tok-123")
    }
}
