import Foundation
import Security

final class KeychainStore {
    static let shared = KeychainStore()

    private let service = "com.ipavault.app.secure"
    private let accountKey = "saved_apple_accounts_v2"
    private let deviceGuidKey = "stable_device_guid_v1"
    private let engineDefaultsKey = "selected_auth_engine_v1"

    private init() {}

    // MARK: - Stable Device GUID (Required before any Apple Store network request)

    func loadOrCreateDeviceGUID() -> String {
        if let existing = readString(account: deviceGuidKey), existing.count == 12 {
            return existing
        }
        let bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        let generated = bytes.map { String(format: "%02X", $0) }.joined()
        saveString(generated, account: deviceGuidKey)
        return generated
    }

    // MARK: - Selected Auth Engine Preference

    func loadSelectedEngine() -> AuthEngineMode {
        guard let raw = UserDefaults.standard.string(forKey: engineDefaultsKey),
              let mode = AuthEngineMode(rawValue: raw) else {
            return .applePackage
        }
        return mode
    }

    func saveSelectedEngine(_ mode: AuthEngineMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: engineDefaultsKey)
    }

    // MARK: - Accounts (Encrypted in Keychain)

    func saveAccounts(_ accounts: [AppleAccount]) throws {
        let data = try JSONEncoder().encode(accounts)
        try writeData(data, account: accountKey)
    }

    func loadAccounts() -> [AppleAccount] {
        guard let data = readData(account: accountKey) else {
            return []
        }
        return (try? JSONDecoder().decode([AppleAccount].self, from: data)) ?? []
    }

    func clearAllAccounts() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Low-level Keychain Helpers

    private func writeData(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
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

    private func readData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }

    private func saveString(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        try? writeData(data, account: account)
    }

    private func readString(account: String) -> String? {
        guard let data = readData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
