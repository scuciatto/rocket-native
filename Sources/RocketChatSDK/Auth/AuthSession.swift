import Foundation

/// Holds the live credentials for one server connection.
actor AuthSession {
    private(set) var credentials: AuthCredentials?
    private(set) var profile: UserProfile?

    func set(_ credentials: AuthCredentials?) {
        self.credentials = credentials
        if credentials == nil {
            profile = nil
        }
    }

    func setProfile(_ profile: UserProfile?) {
        self.profile = profile
    }

    /// Author stamp for optimistic local messages.
    var miniUser: MiniUser {
        MiniUser(
            _id: profile?._id ?? credentials?.userId ?? "",
            username: profile?.username,
            name: profile?.name)
    }

    var headers: [String: String] {
        guard let credentials else { return [:] }
        return [
            "X-Auth-Token": credentials.authToken,
            "X-User-Id": credentials.userId,
        ]
    }
}
