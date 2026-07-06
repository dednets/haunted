import Foundation
import Security

/// Persists the Haunted refresh token in the macOS Keychain so the session
/// survives app restarts. Only the long-lived refresh token is stored; access
/// tokens are minted on demand and never persisted.
enum HauntedKeychain {
    private static let service = "com.thenets.haunted.refresh-token"

    struct StoredSession: Codable {
        let consoleURL: String
        let refreshToken: String
    }

    static func save(_ session: StoredSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let account = accountKey(for: session.consoleURL)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    /// Returns a stored session, if any. Requesting raw data requires
    /// `kSecMatchLimitOne`; combining data with `kSecMatchLimitAll` returns
    /// errSecParam on macOS.
    static func load() -> StoredSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                NSLog("[haunted] keychain load status=%d", Int(status))
            }
            return nil
        }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    static func clear(consoleURL: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey(for: consoleURL),
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func accountKey(for consoleURL: String) -> String {
        URL(string: consoleURL)?.host.map { host in
            "\(host)"
        } ?? consoleURL
    }
}
