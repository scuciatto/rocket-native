import Foundation

/// Executes typed endpoints against one server, handling the concerns every
/// call shares: auth headers, the generic 2FA replay contract, rate limiting,
/// and error-envelope parsing.
actor RESTClient {
    private let baseURL: URL
    private let transport: HTTPTransport
    private let auth: AuthSession
    private let rateLimiter: RateLimiter
    private let clock: RESTClock
    private let decoder = RCJSON.decoder()

    init(
        serverURL: URL,
        transport: HTTPTransport,
        auth: AuthSession,
        clock: RESTClock = SystemClock()
    ) {
        self.baseURL = serverURL
        self.transport = transport
        self.auth = auth
        self.clock = clock
        self.rateLimiter = RateLimiter(clock: clock)
    }

    /// Answers mid-session 2FA challenges on authenticated calls. Login,
    /// resume and `sendEmailCode` (`requiresAuth: false`) never consult it.
    private var twoFactorProvider: TwoFactorCodeProvider?

    func setTwoFactorProvider(_ provider: TwoFactorCodeProvider?) {
        twoFactorProvider = provider
    }

    func send<R>(_ endpoint: Endpoint<R>) async throws -> R {
        let request = try await buildRequest(for: endpoint)
        do {
            return try await execute(request, path: endpoint.path, allowRateLimitRetry: true)
        } catch RocketChatError.twoFactorRequired(let challenge) {
            guard endpoint.requiresAuth, let provider = twoFactorProvider else {
                throw RocketChatError.twoFactorRequired(challenge)
            }
            return try await resolve(challenge, with: provider, expecting: R.self)
        }
    }

    /// Replays a 2FA-challenged request with the code headers attached.
    /// `R` must match the response type of the endpoint that raised the challenge.
    /// The headers live only on this one-off request, never in shared state,
    /// so later calls can't leak a stale code.
    func replay<R: Decodable & Sendable>(
        _ challenge: TwoFactorChallenge,
        code: String,
        method: TwoFactorMethod? = nil,
        expecting: R.Type
    ) async throws -> R {
        let method = method ?? challenge.method
        var request = challenge.request
        request.setValue(method.headerValue(for: code), forHTTPHeaderField: "x-2fa-code")
        request.setValue(method.rawValue, forHTTPHeaderField: "x-2fa-method")
        do {
            return try await execute(
                request, path: challenge.endpointPath, allowRateLimitRetry: true)
        } catch RocketChatError.twoFactorInvalid(let fresh) {
            throw RocketChatError.twoFactorInvalid(fresh.inheriting(from: challenge))
        }
    }

    /// Prompt-and-replay loop for a mid-session challenge: re-prompts on a
    /// wrong code, throws `.cancelled` when the provider returns nil, and
    /// tells the provider the challenge ended exactly once, however it ends.
    private func resolve<R: Decodable & Sendable>(
        _ challenge: TwoFactorChallenge,
        with provider: TwoFactorCodeProvider,
        expecting: R.Type
    ) async throws -> R {
        var current = challenge
        let outcome: Result<R, Error>
        do {
            outcome = .success(
                try await promptUntilAccepted(&current, with: provider, expecting: R.self))
        } catch {
            outcome = .failure(error)
        }
        // `defer` can't await, so the single end-of-challenge call sits here.
        await provider.challengeEnded(current)
        return try outcome.get()
    }

    /// Asks for codes until one is accepted; `current` tracks the latest
    /// (retry) challenge so the caller can report the one that ended.
    private func promptUntilAccepted<R: Decodable & Sendable>(
        _ current: inout TwoFactorChallenge,
        with provider: TwoFactorCodeProvider,
        expecting: R.Type
    ) async throws -> R {
        while true {
            guard let code = await provider.code(for: current) else {
                throw RocketChatError.cancelled
            }
            do {
                return try await replay(current, code: code, expecting: R.self)
            } catch RocketChatError.twoFactorInvalid(let fresh) {
                current = fresh
            }
        }
    }

    // MARK: - Internals

    private func buildRequest<R>(for endpoint: Endpoint<R>) async throws -> URLRequest {
        guard
            var components = URLComponents(
                url: baseURL.appending(path: "api/v1/\(endpoint.path)"),
                resolvingAgainstBaseURL: false)
        else { throw RocketChatError.invalidServerURL }

        if !endpoint.queryItems.isEmpty {
            components.queryItems = endpoint.queryItems
        }
        guard let url = components.url else { throw RocketChatError.invalidServerURL }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.setValue(
            endpoint.contentType ?? "application/json",
            forHTTPHeaderField: "Content-Type")
        request.httpBody = endpoint.body

        if endpoint.requiresAuth {
            let headers = await auth.headers
            guard !headers.isEmpty else { throw RocketChatError.notAuthenticated }
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        return request
    }

    private func execute<R: Decodable & Sendable>(
        _ request: URLRequest,
        path: String,
        allowRateLimitRetry: Bool
    ) async throws -> R {
        let waitTime = await rateLimiter.waitTime(for: path)
        try await clock.sleep(seconds: waitTime)

        let (data, response) = try await transport.send(request)
        await rateLimiter.record(path: path, response: response)

        switch response.statusCode {
        case 200...299:
            do {
                return try decoder.decode(R.self, from: data)
            } catch {
                throw RocketChatError.decoding(description: "\(error)", endpoint: path)
            }
        case 401:
            // Login reports 2FA as a 401; anything else is bad credentials.
            let error = errorFor(status: 401, data: data, request: request, path: path)
            switch error {
            case .twoFactorRequired, .twoFactorInvalid, .httpError(_, "totp-max-attempts", _):
                throw error
            default:
                throw RocketChatError.notAuthenticated
            }
        case 429:
            let retryDate = await rateLimiter.retryDate(for: path, response: response)
            guard allowRateLimitRetry else {
                throw RocketChatError.rateLimited(retryAfter: retryDate)
            }
            try await clock.sleep(seconds: retryDate.timeIntervalSince(clock.now))
            return try await execute(request, path: path, allowRateLimitRetry: false)
        default:
            throw errorFor(status: response.statusCode, data: data, request: request, path: path)
        }
    }

    private func errorFor(
        status: Int, data: Data, request: URLRequest, path: String
    ) -> RocketChatError {
        let body = try? decoder.decode(APIErrorBody.self, from: data)
        // REST calls put the code in `errorType`; the login envelope uses `error`.
        let code = body?.errorType ?? body?.error

        if code == "totp-required" || code == "totp-invalid" {
            var cleanRequest = request
            cleanRequest.setValue(nil, forHTTPHeaderField: "x-2fa-code")
            cleanRequest.setValue(nil, forHTTPHeaderField: "x-2fa-method")
            let challenge = TwoFactorChallenge(
                availableMethods: (body?.details?.availableMethods ?? [])
                    .compactMap(TwoFactorMethod.init(rawValue:)),
                defaultMethod: body?.details?.method
                    .flatMap(TwoFactorMethod.init(rawValue:)),
                emailCodeGenerated: body?.details?.codeGenerated ?? false,
                emailOrUsername: body?.details?.emailOrUsername,
                isRetry: code == "totp-invalid",
                request: cleanRequest,
                endpointPath: path)
            return code == "totp-required"
                ? .twoFactorRequired(challenge)
                : .twoFactorInvalid(challenge)
        }

        return .httpError(
            status: status,
            errorType: code == "totp-max-attempts" ? code : body?.errorType,
            message: body?.message ?? body?.error)
    }
}
