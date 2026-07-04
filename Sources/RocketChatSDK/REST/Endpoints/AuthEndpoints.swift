import Foundation

struct LoginResponse: Decodable, Sendable {
    var data: LoginData

    struct LoginData: Decodable, Sendable {
        var authToken: String
        var userId: String
        var me: UserProfile?
    }
}

/// `/api/v1/me` returns the user's fields at the top level.
typealias MeResponse = UserProfile

enum API {
    enum Auth {
        static func login(user: String, password: String) -> Endpoint<LoginResponse> {
            struct Body: Encodable {
                var user: String
                var password: String
            }
            return .post(
                "login", body: Body(user: user, password: password), requiresAuth: false)
        }

        static func resume(token: String) -> Endpoint<LoginResponse> {
            struct Body: Encodable {
                var resume: String
            }
            return .post("login", body: Body(resume: token), requiresAuth: false)
        }

        static func me() -> Endpoint<MeResponse> {
            .get("me")
        }

        static func logout() -> Endpoint<SuccessResponse> {
            Endpoint(path: "logout", method: .post)
        }

        static func sendEmailCode(emailOrUsername: String) -> Endpoint<SuccessResponse> {
            struct Body: Encodable {
                var emailOrUsername: String
            }
            return .post(
                "users.2fa.sendEmailCode",
                body: Body(emailOrUsername: emailOrUsername),
                requiresAuth: false)
        }
    }
}
