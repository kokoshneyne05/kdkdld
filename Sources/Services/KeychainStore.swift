import Foundation
import Security

final class KeychainStore {
    static let shared = KeychainStore()

    private let service = "com.ipavault.app.accounts"
    private let accountKey = "saved_apple_accounts_v1"

    private init() {}

    func saveAccounts(_ accounts: [AppleAccount]) throws {
        let data = try JSONEncoder().encode(accounts)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw StoreError.networkError("Ошибка записи Keychain (код \(addStatus))")
            }
        } else if status != errSecSuccess {
            throw StoreError.networkError("Ошибка обновления Keychain (код \(status))")
        }
    }

    func loadAccounts() -> [AppleAccount] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return []
        }

        return (try? JSONDecoder().decode([AppleAccount].self, from: data)) ?? []
    }

    func clearAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey
        ]
        SecItemDelete(query as CFDictionary)
    }
}
