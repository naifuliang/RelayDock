import Foundation
import Security

enum KeychainStore {
    private static let service = "app.relaydock.credentials"
    private static let legacyAccount = "gateway-api-key"

    static func saveAPIKey(_ value: String, for profileID: UUID) throws {
        try save(value, account: account(for: profileID))
    }

    static func loadAPIKey(for profileID: UUID) -> String {
        load(account: account(for: profileID))
    }

    static func removeAPIKey(for profileID: UUID) throws {
        try remove(account: account(for: profileID))
    }

    static func migrateLegacyAPIKey(to profileID: UUID) throws -> String {
        let legacyValue = loadLegacyAPIKey()
        guard !legacyValue.isEmpty else { return "" }
        try saveAPIKey(legacyValue, for: profileID)
        guard loadAPIKey(for: profileID) == legacyValue else {
            throw KeychainMigrationError.verificationFailed
        }
        return legacyValue
    }

    static func loadLegacyAPIKey() -> String {
        load(account: legacyAccount)
    }

    static func removeLegacyAPIKey() throws {
        try remove(account: legacyAccount)
    }

    private static func account(for profileID: UUID) -> String {
        "gateway-api-key.\(profileID.uuidString.lowercased())"
    }

    private static func save(_ value: String, account: String) throws {
        let query = query(account: account)
        guard !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
            return
        }

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: Data(value.utf8)] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError(status: updateStatus) }

        var item = query
        item.removeValue(forKey: kSecUseAuthenticationUI as String)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private static func load(account: String) -> String {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func remove(account: String) throws {
        let query = query(account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    static func removeAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // LAContext.interactionNotAllowed does not suppress every legacy
            // Keychain ACL prompt. This query flag guarantees fail-closed,
            // non-interactive access after a signing identity change.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}

enum KeychainMigrationError: LocalizedError {
    case verificationFailed
    case profilePersistenceFailed

    var errorDescription: String? {
        switch self {
        case .verificationFailed: return "迁移后的 API Key 无法从 Keychain 读取。"
        case .profilePersistenceFailed: return "无法持久化多端点配置。"
        }
    }
}

enum LegacyProfileMigrator {
    static func migrate(
        saveAndVerifyKey: () throws -> String,
        persistProfiles: () -> Bool,
        removeLegacyKey: () throws -> Void
    ) throws -> String {
        let migratedKey = try saveAndVerifyKey()
        guard persistProfiles() else { throw KeychainMigrationError.profilePersistenceFailed }
        try? removeLegacyKey()
        return migratedKey
    }
}
