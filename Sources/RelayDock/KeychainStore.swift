import Foundation
import LocalAuthentication
import Security

enum KeychainStore {
    private static let service = "app.relaydock.credentials"
    private static let vaultAccount = "credential-vault.v1"
    private static let legacyAccount = "gateway-api-key"

    enum Presence: Equatable {
        case absent
        case present
        case protected
        case unavailable(OSStatus)

        var mayExist: Bool {
            switch self {
            case .present, .protected, .unavailable: return true
            case .absent: return false
            }
        }
    }

    struct MigrationReport: Equatable {
        let migratedProfileCount: Int
        let unresolvedProfileCount: Int
        let migratedLegacyKey: Bool
    }

    private struct CredentialVault: Codable, Equatable {
        var keys: [String: String] = [:]
    }

    private enum AccessMode: Equatable {
        case nonInteractive
        case userInitiated
    }

    static func credentialPresence(for profileID: UUID, includeLegacyKey: Bool = false) -> Presence {
        // Presence checks intentionally request attributes only. They are safe
        // to use at launch because no credential bytes are returned.
        let vaultPresence = itemPresence(account: vaultAccount)
        if vaultPresence.mayExist { return vaultPresence }
        let profilePresence = itemPresence(account: legacyProfileAccount(for: profileID))
        if profilePresence.mayExist { return profilePresence }
        return includeLegacyKey ? itemPresence(account: legacyAccount) : .absent
    }

    static func legacyCredentialsMayNeedMigration(profileIDs: [UUID], includeLegacyKey: Bool) -> Bool {
        if includeLegacyKey, itemPresence(account: legacyAccount).mayExist { return true }
        return profileIDs.contains { itemPresence(account: legacyProfileAccount(for: $0)).mayExist }
    }

    /// Reads a credential only after a user action. If it still lives in a
    /// pre-v0.5.1 item, the value is copied into the single vault and the old
    /// item is removed non-interactively when macOS permits it.
    static func loadAPIKeyForUserAction(for profileID: UUID, includeLegacyKey: Bool = false) throws -> String {
        var vault = try loadVault(mode: .userInitiated)
        let vaultKey = vaultKey(for: profileID)
        if let value = vault.keys[vaultKey] { return value }

        let oldAccount = legacyProfileAccount(for: profileID)
        if let value = try loadItem(account: oldAccount, mode: .userInitiated) {
            vault.keys[vaultKey] = value
            try saveVault(vault, mode: .userInitiated)
            try? removeItem(account: oldAccount, mode: .nonInteractive)
            return value
        }

        if includeLegacyKey,
           let value = try loadItem(account: legacyAccount, mode: .userInitiated) {
            vault.keys[vaultKey] = value
            try saveVault(vault, mode: .userInitiated)
            try? removeItem(account: legacyAccount, mode: .nonInteractive)
            return value
        }
        return ""
    }

    static func saveAPIKey(_ value: String, for profileID: UUID) throws {
        var vault = try loadVault(mode: .userInitiated)
        let key = vaultKey(for: profileID)
        if value.isEmpty {
            vault.keys.removeValue(forKey: key)
        } else {
            vault.keys[key] = value
        }
        try saveVault(vault, mode: .userInitiated)
        try? removeItem(account: legacyProfileAccount(for: profileID), mode: .nonInteractive)
    }

    static func removeAPIKey(for profileID: UUID) throws {
        try saveAPIKey("", for: profileID)
        try? removeItem(account: legacyProfileAccount(for: profileID), mode: .userInitiated)
    }

    static func migrateCredentials(profileIDs: [UUID], legacyProfileID: UUID?) throws -> MigrationReport {
        var vault = try loadVault(mode: .userInitiated)
        var migrated = 0
        var unresolved = 0
        var migratedLegacyKey = false

        for profileID in profileIDs {
            let key = vaultKey(for: profileID)
            if vault.keys[key] != nil { continue }
            do {
                if let value = try loadItem(
                    account: legacyProfileAccount(for: profileID),
                    mode: .userInitiated
                ) {
                    vault.keys[key] = value
                    migrated += 1
                }
            } catch {
                unresolved += 1
            }
        }

        if let legacyProfileID, vault.keys[vaultKey(for: legacyProfileID)] == nil {
            do {
                if let value = try loadItem(account: legacyAccount, mode: .userInitiated) {
                    vault.keys[vaultKey(for: legacyProfileID)] = value
                    migratedLegacyKey = true
                }
            } catch {
                unresolved += 1
            }
        }

        try saveVault(vault, mode: .userInitiated)
        guard try loadVault(mode: .nonInteractive) == vault else {
            throw KeychainMigrationError.verificationFailed
        }

        for profileID in profileIDs where vault.keys[vaultKey(for: profileID)] != nil {
            try? removeItem(account: legacyProfileAccount(for: profileID), mode: .nonInteractive)
        }
        if migratedLegacyKey {
            try? removeItem(account: legacyAccount, mode: .nonInteractive)
        }
        return MigrationReport(
            migratedProfileCount: migrated,
            unresolvedProfileCount: unresolved,
            migratedLegacyKey: migratedLegacyKey
        )
    }

    static func removeAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    static func query(account: String, allowInteraction: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if !allowInteraction {
            // Startup and passive UI paths must fail closed instead of asking
            // for a login-keychain password.
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            // Some legacy generic-password ACLs still ignore LAContext's
            // interactionNotAllowed flag. Keep the older fail-closed switch as
            // a second guard; no passive query may display authorization UI.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        return query
    }

    private static func vaultKey(for profileID: UUID) -> String {
        profileID.uuidString.lowercased()
    }

    private static func legacyProfileAccount(for profileID: UUID) -> String {
        "gateway-api-key.\(profileID.uuidString.lowercased())"
    }

    private static func itemPresence(account: String) -> Presence {
        var query = query(account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess: return .present
        case errSecItemNotFound: return .absent
        case errSecInteractionNotAllowed, errSecAuthFailed: return .protected
        case let status: return .unavailable(status)
        }
    }

    private static func loadVault(mode: AccessMode) throws -> CredentialVault {
        guard let data = try loadItemData(account: vaultAccount, mode: mode) else {
            return CredentialVault()
        }
        do {
            return try JSONDecoder().decode(CredentialVault.self, from: data)
        } catch {
            throw KeychainMigrationError.invalidVault
        }
    }

    private static func saveVault(_ vault: CredentialVault, mode: AccessMode) throws {
        if vault.keys.isEmpty {
            try removeItem(account: vaultAccount, mode: mode)
            return
        }
        let data = try JSONEncoder().encode(vault)
        try saveItemData(data, account: vaultAccount, mode: mode)
    }

    private static func loadItem(account: String, mode: AccessMode) throws -> String? {
        guard let data = try loadItemData(account: account, mode: mode) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainMigrationError.invalidCredential
        }
        return value
    }

    private static func loadItemData(account: String, mode: AccessMode) throws -> Data? {
        var itemQuery = query(account: account, allowInteraction: mode == .userInitiated)
        itemQuery[kSecReturnData as String] = true
        itemQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(itemQuery as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return data
    }

    private static func saveItemData(_ data: Data, account: String, mode: AccessMode) throws {
        let itemQuery = query(account: account, allowInteraction: mode == .userInitiated)
        let updateStatus = SecItemUpdate(
            itemQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError(status: updateStatus) }

        var item = itemQuery
        item.removeValue(forKey: kSecUseAuthenticationContext as String)
        item.removeValue(forKey: kSecUseAuthenticationUI as String)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private static func removeItem(account: String, mode: AccessMode) throws {
        let itemQuery = query(account: account, allowInteraction: mode == .userInitiated)
        let status = SecItemDelete(itemQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
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
    case invalidVault
    case invalidCredential

    var errorDescription: String? {
        switch self {
        case .verificationFailed: return "迁移后的 API Key 无法从 Keychain 读取。"
        case .profilePersistenceFailed: return "无法持久化多端点配置。"
        case .invalidVault: return "RelayDock Keychain 凭据仓库已损坏，未进行覆盖。"
        case .invalidCredential: return "旧 API Key 不是有效的 UTF-8 数据，未进行迁移。"
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

struct CredentialStoreClient {
    var presence: (UUID, Bool) -> KeychainStore.Presence
    var migrationNeeded: ([UUID], Bool) -> Bool
    var loadForUserAction: (UUID, Bool) throws -> String
    var save: (String, UUID) throws -> Void
    var remove: (UUID) throws -> Void
    var migrate: ([UUID], UUID?) throws -> KeychainStore.MigrationReport
    var removeAll: () throws -> Void

    static let live = CredentialStoreClient(
        presence: { KeychainStore.credentialPresence(for: $0, includeLegacyKey: $1) },
        migrationNeeded: { KeychainStore.legacyCredentialsMayNeedMigration(profileIDs: $0, includeLegacyKey: $1) },
        loadForUserAction: { try KeychainStore.loadAPIKeyForUserAction(for: $0, includeLegacyKey: $1) },
        save: { try KeychainStore.saveAPIKey($0, for: $1) },
        remove: { try KeychainStore.removeAPIKey(for: $0) },
        migrate: { try KeychainStore.migrateCredentials(profileIDs: $0, legacyProfileID: $1) },
        removeAll: { try KeychainStore.removeAll() }
    )
}
