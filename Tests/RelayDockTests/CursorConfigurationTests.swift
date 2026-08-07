import Foundation
import SQLite3
import XCTest
@testable import RelayDock

final class CursorConfigurationTests: XCTestCase {
    private var root: URL!
    private var databaseURL: URL!
    private var backupDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockCursorTests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = root.appendingPathComponent("state.vscdb")
        backupDirectory = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try createFixture()
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func testApplyWritesRoutesModelsAndLegacyMigrationKeysThenRollbackRestoresExactly() throws {
        let originalStorage = try databaseValue(forKey: CursorConfiguration.persistentStorageKey)
        let receipt = try CursorConfiguration.apply(
            CursorImportRequest(
                openAIBaseURL: "https://gateway.example/v1/",
                openAIKey: "  openai-secret  ",
                anthropicKey: "anthropic-secret",
                modelIDs: ["gpt-test", "claude-test", "gpt-test"]
            ),
            databaseURL: databaseURL,
            backupDirectory: backupDirectory,
            cursorVersion: "3.14.7",
            requireCursorQuit: false
        )

        let storageData = try XCTUnwrap(try databaseValue(forKey: CursorConfiguration.persistentStorageKey)?.data(using: .utf8))
        let storage = try XCTUnwrap(try JSONSerialization.jsonObject(with: storageData) as? [String: Any])
        XCTAssertEqual(storage["openAIBaseUrl"] as? String, "https://gateway.example/v1")
        XCTAssertEqual(storage["useOpenAIKey"] as? Bool, true)
        XCTAssertEqual(storage["useClaudeKey"] as? Bool, true)
        let settings = try XCTUnwrap(storage["aiSettings"] as? [String: Any])
        XCTAssertEqual(settings["userAddedModels"] as? [String], ["existing-model", "gpt-test", "claude-test"])
        XCTAssertEqual(settings["modelOverrideEnabled"] as? [String], ["existing-model", "gpt-test", "claude-test"])
        XCTAssertEqual(settings["modelOverrideDisabled"] as? [String], ["disabled-model"])
        XCTAssertEqual(try databaseValue(forKey: CursorConfiguration.openAILegacyKey), "openai-secret")
        XCTAssertEqual(try databaseValue(forKey: CursorConfiguration.claudeLegacyKey), "anthropic-secret")
        XCTAssertNil(try databaseValue(forKey: CursorConfiguration.openAISecretKey))
        XCTAssertNil(try databaseValue(forKey: CursorConfiguration.claudeSecretKey))

        let attributes = try FileManager.default.attributesOfItem(atPath: receipt.backupURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        try CursorConfiguration.rollback(receipt, databaseURL: databaseURL)
        XCTAssertEqual(try databaseValue(forKey: CursorConfiguration.persistentStorageKey), originalStorage)
        XCTAssertEqual(try databaseValue(forKey: CursorConfiguration.openAISecretKey), "old-openai-encrypted")
        XCTAssertEqual(try databaseValue(forKey: CursorConfiguration.claudeSecretKey), "old-claude-encrypted")
        XCTAssertNil(try databaseValue(forKey: CursorConfiguration.openAILegacyKey))
        XCTAssertNil(try databaseValue(forKey: CursorConfiguration.claudeLegacyKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.backupURL.path))
    }

    func testFinalizeRequiresCursorToRemoveTemporaryPlaintextKey() throws {
        let receipt = try CursorConfiguration.apply(
            CursorImportRequest(
                openAIBaseURL: "https://gateway.example/v1",
                openAIKey: "openai-secret",
                anthropicKey: nil,
                modelIDs: []
            ),
            databaseURL: databaseURL,
            backupDirectory: backupDirectory,
            cursorVersion: "3.14.7",
            requireCursorQuit: false
        )
        XCTAssertThrowsError(try CursorConfiguration.finalize(receipt, databaseURL: databaseURL))
        try removeValue(forKey: CursorConfiguration.openAILegacyKey)
        try setValue("new-openai-encrypted", forKey: CursorConfiguration.openAISecretKey)
        try CursorConfiguration.finalize(receipt, databaseURL: databaseURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.backupURL.path))
    }

    func testFinalizeRequiresEncryptedSecretAfterPlaintextIsRemoved() throws {
        let receipt = try CursorConfiguration.apply(
            CursorImportRequest(
                openAIBaseURL: "https://gateway.example/v1",
                openAIKey: "openai-secret",
                anthropicKey: nil,
                modelIDs: []
            ),
            databaseURL: databaseURL,
            backupDirectory: backupDirectory,
            cursorVersion: "3.14.7",
            requireCursorQuit: false
        )
        try removeValue(forKey: CursorConfiguration.openAILegacyKey)

        XCTAssertThrowsError(try CursorConfiguration.finalize(receipt, databaseURL: databaseURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.backupURL.path))
    }

    func testRejectsUnknownCursorMajorBeforeWriting() throws {
        XCTAssertThrowsError(try CursorConfiguration.apply(
            CursorImportRequest(
                openAIBaseURL: "https://gateway.example/v1",
                openAIKey: "key",
                anthropicKey: nil,
                modelIDs: []
            ),
            databaseURL: databaseURL,
            backupDirectory: backupDirectory,
            cursorVersion: "4.0.0",
            requireCursorQuit: false
        ))
        XCTAssertEqual(try databaseValue(forKey: CursorConfiguration.openAISecretKey), "old-openai-encrypted")
    }

    func testRollbackLatestRestoresPendingSnapshot() throws {
        let originalStorage = try databaseValue(forKey: CursorConfiguration.persistentStorageKey)
        _ = try CursorConfiguration.apply(
            CursorImportRequest(
                openAIBaseURL: "https://gateway.example/v1",
                openAIKey: "new-key",
                anthropicKey: nil,
                modelIDs: ["gpt-test"]
            ),
            databaseURL: databaseURL,
            backupDirectory: backupDirectory,
            cursorVersion: "3.14.7",
            requireCursorQuit: false
        )

        try CursorConfiguration.rollbackLatest(databaseURL: databaseURL, directory: backupDirectory)

        XCTAssertEqual(try databaseValue(forKey: CursorConfiguration.persistentStorageKey), originalStorage)
        XCTAssertEqual(try databaseValue(forKey: CursorConfiguration.openAISecretKey), "old-openai-encrypted")
        XCTAssertNil(try databaseValue(forKey: CursorConfiguration.openAILegacyKey))
    }

    func testCursorModelRoutingMatchesCursorsClaudePrefixDispatch() {
        let models = [
            GatewayModel(modelID: "gpt-5", isVerified: true),
            GatewayModel(modelID: "claude-sonnet-4", isVerified: true),
            GatewayModel(modelID: "unverified", isVerified: false),
            GatewayModel(modelID: "disabled", isEnabled: false, isVerified: true)
        ]
        let openAI = GatewayProfile(provider: .openAICompatible, models: models)
        let anthropic = GatewayProfile(provider: .anthropic, models: models)
        let responses = GatewayProfile(provider: .openAIResponses, models: models)
        XCTAssertEqual(CursorModelRouting.modelIDs(for: openAI), ["gpt-5"])
        XCTAssertEqual(CursorModelRouting.modelIDs(for: anthropic), ["claude-sonnet-4"])
        XCTAssertEqual(CursorModelRouting.modelIDs(for: responses), [])
    }

    private func createFixture() throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version=1", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE ItemTable (key TEXT UNIQUE, value BLOB)", nil, nil, nil), SQLITE_OK)
        let storage: [String: Any] = [
            "openAIBaseUrl": "https://old.example/v1",
            "useOpenAIKey": false,
            "aiSettings": [
                "userAddedModels": ["existing-model"],
                "modelOverrideEnabled": ["existing-model"],
                "modelOverrideDisabled": ["disabled-model", "gpt-test"]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: storage, options: [.sortedKeys])
        try setValue(String(decoding: data, as: UTF8.self), forKey: CursorConfiguration.persistentStorageKey, database: database)
        try setValue("old-openai-encrypted", forKey: CursorConfiguration.openAISecretKey, database: database)
        try setValue("old-claude-encrypted", forKey: CursorConfiguration.claudeSecretKey, database: database)
    }

    private func databaseValue(forKey key: String) throws -> String? {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else { throw TestError.sqlite }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT CAST(value AS TEXT) FROM ItemTable WHERE key=?1", -1, &statement, nil) == SQLITE_OK else {
            throw TestError.sqlite
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    private func setValue(_ value: String, forKey key: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else { throw TestError.sqlite }
        defer { sqlite3_close(database) }
        try setValue(value, forKey: key, database: database)
    }

    private func setValue(_ value: String, forKey key: String, database: OpaquePointer? = nil) throws {
        var ownedDatabase: OpaquePointer?
        let handle: OpaquePointer?
        if let database {
            handle = database
        } else {
            guard sqlite3_open(databaseURL.path, &ownedDatabase) == SQLITE_OK else { throw TestError.sqlite }
            handle = ownedDatabase
        }
        defer { if ownedDatabase != nil { sqlite3_close(ownedDatabase) } }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "INSERT OR REPLACE INTO ItemTable(key,value) VALUES(?1,?2)", -1, &statement, nil) == SQLITE_OK else {
            throw TestError.sqlite
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        sqlite3_bind_text(statement, 2, value, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw TestError.sqlite }
    }

    private func removeValue(forKey key: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else { throw TestError.sqlite }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM ItemTable WHERE key=?1", -1, &statement, nil) == SQLITE_OK else {
            throw TestError.sqlite
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw TestError.sqlite }
    }

    private enum TestError: Error { case sqlite }
}
