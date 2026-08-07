import Foundation
import SQLite3

enum CursorModelRouting {
    static func modelIDs(for profile: GatewayProfile) -> [String] {
        profile.models.compactMap { model in
            guard model.isEnabled, model.isVerified else { return nil }
            let modelID = model.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty else { return nil }
            let isClaudeRoute = modelID.lowercased().hasPrefix("claude-")
            switch profile.provider {
            case .anthropic: return isClaudeRoute ? modelID : nil
            case .openAICompatible: return isClaudeRoute ? nil : modelID
            case .openAIResponses, .azureOpenAI: return nil
            }
        }
    }
}

struct CursorImportRequest: Equatable {
    let openAIBaseURL: String?
    let openAIKey: String?
    let anthropicKey: String?
    let modelIDs: [String]
}

struct CursorImportReceipt: Equatable {
    let backupURL: URL
    let importedModelIDs: [String]
    let expectedMigrations: [CursorKeyMigration]
}

struct CursorKeyMigration: Equatable {
    let legacyKey: String
    let secretKey: String
}

enum CursorConfiguration {
    static let persistentStorageKey =
        "src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser"
    static let openAILegacyKey = "cursorAuth/openAIKey"
    static let openAISecretKey = "secret://cursorAuth/openAIKey"
    static let claudeLegacyKey = "cursorAuth/claudeKey"
    static let claudeSecretKey = "secret://cursorAuth/claudeKey"

    private static let affectedKeys = [
        persistentStorageKey,
        openAILegacyKey,
        openAISecretKey,
        claudeLegacyKey,
        claudeSecretKey
    ]

    static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    static var backupDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RelayDock/Cursor", isDirectory: true)
    }

    static func apply(
        _ request: CursorImportRequest,
        databaseURL: URL = databaseURL,
        backupDirectory: URL = backupDirectory,
        cursorVersion: String? = CursorLauncher.installedVersion,
        requireCursorQuit: Bool = true
    ) throws -> CursorImportReceipt {
        if requireCursorQuit, CursorLauncher.isRunning {
            throw CursorConfigurationError.cursorIsRunning
        }
        try validate(request)
        try validateCursorVersion(cursorVersion)

        let database = try SQLiteDatabase(url: databaseURL)
        try validateSchema(database)
        guard let storageValue = try database.value(forKey: persistentStorageKey),
              let storageData = storageValue.data(using: .utf8),
              var storage = try JSONSerialization.jsonObject(with: storageData) as? [String: Any] else {
            throw CursorConfigurationError.unsupportedStorage
        }

        let models = normalizedModels(request.modelIDs)
        if let baseURL = request.openAIBaseURL,
           let normalizedURL = EndpointValidator.normalizedURL(from: baseURL) {
            storage["openAIBaseUrl"] = normalizedURL.absoluteString
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            storage["useOpenAIKey"] = true
        }
        if request.anthropicKey != nil {
            storage["useClaudeKey"] = true
        }
        mergeModels(models, into: &storage)
        let updatedStorage = try JSONSerialization.data(withJSONObject: storage, options: [.sortedKeys])
        guard let updatedStorageValue = String(data: updatedStorage, encoding: .utf8) else {
            throw CursorConfigurationError.unsupportedStorage
        }

        let snapshot = CursorConfigurationSnapshot(
            createdAt: Date(),
            databasePath: databaseURL.path,
            records: try affectedKeys.map { key in
                CursorConfigurationSnapshot.Record(key: key, value: try database.value(forKey: key))
            }
        )
        let backupURL = try writeSnapshot(snapshot, directory: backupDirectory)

        do {
            try database.transaction {
                try database.setValue(updatedStorageValue, forKey: persistentStorageKey)
                if let key = request.openAIKey?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    try database.removeValue(forKey: openAISecretKey)
                    try database.setValue(key, forKey: openAILegacyKey)
                }
                if let key = request.anthropicKey?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    try database.removeValue(forKey: claudeSecretKey)
                    try database.setValue(key, forKey: claudeLegacyKey)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: backupURL)
            throw error
        }
        var expectedMigrations: [CursorKeyMigration] = []
        if request.openAIKey != nil {
            expectedMigrations.append(CursorKeyMigration(
                legacyKey: openAILegacyKey,
                secretKey: openAISecretKey
            ))
        }
        if request.anthropicKey != nil {
            expectedMigrations.append(CursorKeyMigration(
                legacyKey: claudeLegacyKey,
                secretKey: claudeSecretKey
            ))
        }
        return CursorImportReceipt(
            backupURL: backupURL,
            importedModelIDs: models,
            expectedMigrations: expectedMigrations
        )
    }

    static func finalize(
        _ receipt: CursorImportReceipt,
        databaseURL: URL = databaseURL
    ) throws {
        let database = try SQLiteDatabase(url: databaseURL)
        for migration in receipt.expectedMigrations {
            guard try database.value(forKey: migration.legacyKey) == nil,
                  let encryptedValue = try database.value(forKey: migration.secretKey),
                  !encryptedValue.isEmpty else {
                throw CursorConfigurationError.keyMigrationIncomplete
            }
        }
        try FileManager.default.removeItem(at: receipt.backupURL)
    }

    static func rollback(
        _ receipt: CursorImportReceipt,
        databaseURL: URL = databaseURL
    ) throws {
        guard !CursorLauncher.isRunning else { throw CursorConfigurationError.cursorIsRunning }
        let data = try Data(contentsOf: receipt.backupURL)
        let snapshot = try JSONDecoder().decode(CursorConfigurationSnapshot.self, from: data)
        guard snapshot.databasePath == databaseURL.path else {
            throw CursorConfigurationError.invalidBackup
        }
        let database = try SQLiteDatabase(url: databaseURL)
        try validateSchema(database)
        try database.transaction {
            for record in snapshot.records {
                if let value = record.value {
                    try database.setValue(value, forKey: record.key)
                } else {
                    try database.removeValue(forKey: record.key)
                }
            }
        }
        try FileManager.default.removeItem(at: receipt.backupURL)
    }

    static func removeBackups(directory: URL = backupDirectory) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    static func rollbackLatest(
        databaseURL: URL = databaseURL,
        directory: URL = backupDirectory
    ) throws {
        guard !CursorLauncher.isRunning else { throw CursorConfigurationError.cursorIsRunning }
        let fileManager = FileManager.default
        let backups = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let latest = backups
            .filter { $0.lastPathComponent.hasPrefix("rollback-") && $0.pathExtension == "json" }
            .max { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left < right
            }
        guard let latest else { throw CursorConfigurationError.noPendingBackup }
        try rollback(CursorImportReceipt(
            backupURL: latest,
            importedModelIDs: [],
            expectedMigrations: []
        ), databaseURL: databaseURL)
    }

    private static func validate(_ request: CursorImportRequest) throws {
        let openAIKey = request.openAIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let anthropicKey = request.anthropicKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if request.openAIBaseURL == nil, anthropicKey?.isEmpty != false {
            throw CursorConfigurationError.noRouteSelected
        }
        if request.openAIBaseURL != nil, openAIKey?.isEmpty != false {
            throw CursorConfigurationError.missingOpenAIKey
        }
        if request.anthropicKey != nil, anthropicKey?.isEmpty != false {
            throw CursorConfigurationError.missingAnthropicKey
        }
        if let value = request.openAIBaseURL,
           EndpointValidator.normalizedURL(from: value) == nil {
            throw CursorConfigurationError.invalidOpenAIBaseURL
        }
    }

    private static func validateCursorVersion(_ version: String?) throws {
        guard let version,
              let major = Int(version.split(separator: ".").first ?? ""),
              major == 3 else {
            throw CursorConfigurationError.unsupportedCursorVersion(version ?? "unknown")
        }
    }

    private static func validateSchema(_ database: SQLiteDatabase) throws {
        guard try database.userVersion() == 1,
              try database.hasItemTableSchema() else {
            throw CursorConfigurationError.unsupportedDatabaseSchema
        }
    }

    private static func normalizedModels(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && seen.insert(value).inserted ? value : nil
        }
    }

    private static func mergeModels(_ models: [String], into storage: inout [String: Any]) {
        guard !models.isEmpty else { return }
        var settings = storage["aiSettings"] as? [String: Any] ?? [:]
        let existingAdded = settings["userAddedModels"] as? [String] ?? []
        let existingEnabled = settings["modelOverrideEnabled"] as? [String] ?? []
        let disabled = settings["modelOverrideDisabled"] as? [String] ?? []
        settings["userAddedModels"] = normalizedModels(existingAdded + models)
        settings["modelOverrideEnabled"] = normalizedModels(existingEnabled + models)
        settings["modelOverrideDisabled"] = disabled.filter { !models.contains($0) }
        storage["aiSettings"] = settings
    }

    private static func writeSnapshot(
        _ snapshot: CursorConfigurationSnapshot,
        directory: URL
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent("rollback-\(UUID().uuidString).json")
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}

private struct CursorConfigurationSnapshot: Codable {
    struct Record: Codable {
        let key: String
        let value: String?
    }

    let createdAt: Date
    let databasePath: String
    let records: [Record]
}

private final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle { sqlite3_close(handle) }
            throw CursorConfigurationError.database(message)
        }
        sqlite3_busy_timeout(handle, 3_000)
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func value(forKey key: String) throws -> String? {
        var statement: OpaquePointer?
        try prepare("SELECT CAST(value AS TEXT) FROM ItemTable WHERE key = ?1", statement: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, statement: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw error() }
        guard let value = sqlite3_column_text(statement, 0) else { return "" }
        return String(cString: value)
    }

    func setValue(_ value: String, forKey key: String) throws {
        var statement: OpaquePointer?
        try prepare(
            "INSERT INTO ItemTable(key, value) VALUES(?1, ?2) " +
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            statement: &statement
        )
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, statement: statement)
        try bind(value, at: 2, statement: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    func removeValue(forKey key: String) throws {
        var statement: OpaquePointer?
        try prepare("DELETE FROM ItemTable WHERE key = ?1", statement: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, statement: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    func userVersion() throws -> Int32 {
        var statement: OpaquePointer?
        try prepare("PRAGMA user_version", statement: &statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
        return sqlite3_column_int(statement, 0)
    }

    func hasItemTableSchema() throws -> Bool {
        var statement: OpaquePointer?
        try prepare(
            "SELECT COUNT(*) FROM pragma_table_info('ItemTable') " +
                "WHERE (name='key' AND type='TEXT') OR (name='value' AND type='BLOB')",
            statement: &statement
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
        return sqlite3_column_int(statement, 0) == 2
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func prepare(_ sql: String, statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
    }

    private func bind(_ value: String, at index: Int32, statement: OpaquePointer?) throws {
        guard sqlite3_bind_text(statement, index, value, -1, Self.transient) == SQLITE_OK else { throw error() }
    }

    private func error() -> CursorConfigurationError {
        CursorConfigurationError.database(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown")
    }
}

enum CursorConfigurationError: LocalizedError {
    case cursorIsRunning
    case noRouteSelected
    case missingOpenAIKey
    case missingAnthropicKey
    case invalidOpenAIBaseURL
    case unsupportedCursorVersion(String)
    case unsupportedDatabaseSchema
    case unsupportedStorage
    case keyMigrationIncomplete
    case invalidBackup
    case noPendingBackup
    case database(String)

    var errorDescription: String? {
        switch self {
        case .cursorIsRunning: return "请先完全退出 Cursor，再执行一键导入。"
        case .noRouteSelected: return "请至少选择一个 OpenAI Compatible 或 Anthropic Endpoint。"
        case .missingOpenAIKey: return "所选 OpenAI Compatible Endpoint 没有 API Key。"
        case .missingAnthropicKey: return "所选 Anthropic Endpoint 没有 API Key。"
        case .invalidOpenAIBaseURL: return "所选 OpenAI Compatible Base URL 无效。"
        case let .unsupportedCursorVersion(version): return "Cursor \(version) 尚未通过配置导入兼容性验证。"
        case .unsupportedDatabaseSchema: return "Cursor 配置数据库结构已变化，RelayDock 已停止写入。"
        case .unsupportedStorage: return "Cursor 配置数据无法安全解析，RelayDock 未做任何修改。"
        case .keyMigrationIncomplete: return "Cursor 尚未把导入的 Key 迁移到加密存储。"
        case .invalidBackup: return "Cursor 回滚快照与当前数据库不匹配。"
        case .noPendingBackup: return "没有待恢复的 Cursor 配置快照。"
        case let .database(message): return "Cursor 配置数据库错误：\(message)"
        }
    }
}
