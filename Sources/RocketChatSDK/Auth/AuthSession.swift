import Foundation

/// Holds the live credentials for one server connection.
actor AuthSession {
    private(set) var credentials: AuthCredentials?

    func set(_ credentials: AuthCredentials?) {
        self.credentials = credentials
    }

    var headers: [String: String] {
        guard let credentials else { return [:] }
        return [
            "X-Auth-Token": credentials.authToken,
            "X-User-Id": credentials.userId,
        ]
    }
}
