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

    func send<R>(_ endpoint: Endpoint<R>) async throws -> R {
        let request = try await buildRequest(for: endpoint)
        return try await execute(request, path: endpoint.path, allowRateLimitRetry: true)
    }

    /// Replays a 2FA-challenged request with the code headers attached.
    /// `R` must match the response type of the endpoint that raised the challenge.
    func replay<R: Decodable & Sendable>(
        _ challenge: TwoFactorChallenge,
        code: String,
        method: TwoFactorMethod,
        expecting: R.Type
    ) async throws -> R {
        var request = challenge.request
        request.setValue(code, forHTTPHeaderField: "x-2fa-code")
        request.setValue(method.rawValue, forHTTPHeaderField: "x-2fa-method")
        return try await execute(request, path: challenge.endpointPath, allowRateLimitRetry: true)
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
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
            throw RocketChatError.notAuthenticated
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

        if body?.errorType == "totp-required" || body?.errorType == "totp-invalid" {
            var cleanRequest = request
            cleanRequest.setValue(nil, forHTTPHeaderField: "x-2fa-code")
            cleanRequest.setValue(nil, forHTTPHeaderField: "x-2fa-method")
            let challenge = TwoFactorChallenge(
                availableMethods: (body?.details?.availableMethods ?? [])
                    .compactMap(TwoFactorMethod.init(rawValue:)),
                defaultMethod: body?.details?.method
                    .flatMap(TwoFactorMethod.init(rawValue:)),
                emailCodeGenerated: body?.details?.codeGenerated ?? false,
                request: cleanRequest,
                endpointPath: path)
            return body?.errorType == "totp-required"
                ? .twoFactorRequired(challenge)
                : .twoFactorInvalid(challenge)
        }

        return .httpError(
            status: status,
            errorType: body?.errorType,
            message: body?.message ?? body?.error)
    }
}
