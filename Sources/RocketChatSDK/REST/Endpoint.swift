import Foundation

enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
}

/// A typed REST call: `/api/v1/<path>` plus its expected response shape.
/// Bodies are encoded at construction so the value stays `Sendable`.
struct Endpoint<Response: Decodable & Sendable>: Sendable {
    var path: String
    var method: HTTPMethod = .get
    var queryItems: [URLQueryItem] = []
    var body: Data?
    var requiresAuth = true
    /// Overrides the default `application/json` (e.g. multipart uploads).
    var contentType: String?

    static func get(
        _ path: String, query: [URLQueryItem] = [], requiresAuth: Bool = true
    ) -> Endpoint {
        Endpoint(path: path, method: .get, queryItems: query, requiresAuth: requiresAuth)
    }

    static func post(
        _ path: String, body: some Encodable, requiresAuth: Bool = true
    ) -> Endpoint {
        Endpoint(
            path: path, method: .post,
            body: try? RCJSON.encoder().encode(body),
            requiresAuth: requiresAuth)
    }
}

/// Bare `{"success": true}` acknowledgment.
struct SuccessResponse: Decodable, Sendable {
    var success: Bool
}

/// Pagination echo common to list endpoints.
public struct Paginated<Item: Sendable>: Sendable {
    public var items: [Item]
    public var offset: Int
    public var total: Int
}
