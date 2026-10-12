import Foundation
import Security
import RocketChatSDK

/// Credential storage in the login Keychain, one generic-password item per
/// server host. The SDK is storage-agnostic; this is the app's half of that
/// contract.
enum KeychainStore {
    private static let service = "chat.rocket.native-experiment"

    /// Writes only when the stored value differs, and updates in place rather
    /// than delete+add: every Keychain access can prompt, and re-adding an
    /// item resets its access list.
    static func save(_ credentials: AuthCredentials, server: URL) {
        guard let account = server.host(),
              let data = try? JSONEncoder().encode(credentials) else { return }
        if load(server: server) == credentials { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load(server: URL) -> AuthCredentials? {
        guard let account = server.host() else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(AuthCredentials.self, from: data)
    }

    static func delete(server: URL) {
        guard let account = server.host() else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
