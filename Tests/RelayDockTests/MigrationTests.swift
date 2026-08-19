import XCTest
import LocalAuthentication
import Security
@testable import RelayDock

final class MigrationTests: XCTestCase {
    func testLegacyGatewayModelDecodesAsUnverified() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","modelID":"legacy-model","displayName":"Legacy","isEnabled":true}"#.utf8)
        let model = try JSONDecoder().decode(GatewayModel.self, from: data)
        XCTAssertFalse(model.isVerified)
        XCTAssertEqual(model.modelID, "legacy-model")
    }

    func testKeychainQueriesExplicitlyForbidAuthenticationUI() {
        let query = KeychainStore.query(account: "test-account")
        let context = query[kSecUseAuthenticationContext as String] as? LAContext

        XCTAssertNotNil(context)
        XCTAssertEqual(context?.interactionNotAllowed, true)
        let uiPolicy = query[kSecUseAuthenticationUI as String]
        XCTAssertTrue(CFEqual(uiPolicy as CFTypeRef?, kSecUseAuthenticationUIFail))
    }

    func testUserInitiatedKeychainQueryAllowsSystemAuthorization() {
        let query = KeychainStore.query(account: "test-account", allowInteraction: true)
        XCTAssertNil(query[kSecUseAuthenticationContext as String])
        XCTAssertNil(query[kSecUseAuthenticationUI as String])
    }

    @MainActor
    func testStartupAndEndpointSelectionNeverLoadCredentialBytes() {
        let suiteName = "MigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var loadCount = 0
        let store = makeCredentialStore(
            presence: .present,
            load: { _, _ in loadCount += 1; return "secret" }
        )

        let model = AppModel(
            defaults: defaults,
            scheduleAutomaticUpdateCheck: false,
            credentialStore: store
        )
        XCTAssertEqual(loadCount, 0)
        XCTAssertFalse(model.credentialLoaded)
        XCTAssertTrue(model.credentialMayExist)

        model.addProfile()
        XCTAssertEqual(loadCount, 0)
        XCTAssertFalse(model.credentialLoaded)

        model.loadSelectedCredential()
        XCTAssertEqual(loadCount, 1)
        XCTAssertTrue(model.credentialLoaded)
        XCTAssertEqual(model.apiKey, "secret")
    }

    @MainActor
    func testSavingUnloadedProfileDoesNotOverwriteStoredCredential() {
        let suiteName = "MigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var saveCount = 0
        var store = makeCredentialStore(presence: .present)
        store.save = { _, _ in saveCount += 1 }
        let model = AppModel(
            defaults: defaults,
            scheduleAutomaticUpdateCheck: false,
            credentialStore: store
        )
        model.draftProfile.baseURL = "https://gateway.example/v1"

        XCTAssertTrue(model.saveSelectedProfile())
        XCTAssertEqual(saveCount, 0)
        XCTAssertFalse(model.credentialLoaded)
    }

    @MainActor
    func testLegacyCredentialRequiresExplicitRepairBeforeReadingSecret() throws {
        let suiteName = "MigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONEncoder().encode(EndpointProfile(baseURL: "https://legacy.example/v1", displayName: "Legacy")),
            forKey: "endpointProfile"
        )
        var loadCount = 0
        var includedLegacyKey = false
        var store = makeCredentialStore(presence: .present) { _, includeLegacy in
            loadCount += 1
            includedLegacyKey = includeLegacy
            return "legacy-secret"
        }
        store.migrationNeeded = { _, _ in true }

        _ = AppModel(defaults: defaults, scheduleAutomaticUpdateCheck: false, credentialStore: store)
        XCTAssertEqual(loadCount, 0)
        let relaunched = AppModel(defaults: defaults, scheduleAutomaticUpdateCheck: false, credentialStore: store)
        XCTAssertEqual(loadCount, 0)

        relaunched.loadSelectedCredential()
        XCTAssertEqual(loadCount, 0)
        XCTAssertFalse(includedLegacyKey)
        XCTAssertTrue(relaunched.apiKey.isEmpty)
        XCTAssertTrue(relaunched.statusMessage.contains("Repair Keychain once"))
    }

    @MainActor
    func testActualLegacyPresenceOverridesStaleMigrationCompleteDefault() {
        let suiteName = "MigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "credentialVaultMigrationComplete.v1")
        var loadCount = 0
        var store = makeCredentialStore(presence: .protected) { _, _ in
            loadCount += 1
            return "secret"
        }
        store.migrationNeeded = { _, _ in true }

        let model = AppModel(
            defaults: defaults,
            scheduleAutomaticUpdateCheck: false,
            credentialStore: store
        )

        XCTAssertTrue(model.credentialMigrationAvailable)
        model.loadSelectedCredential()
        XCTAssertEqual(loadCount, 0)
    }

    @MainActor
    func testSyncModelsDoesNotReadLegacyCredentialBeforeExplicitRepair() {
        let suiteName = "MigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var loadCount = 0
        var store = makeCredentialStore(presence: .protected) { _, _ in
            loadCount += 1
            return "secret"
        }
        store.migrationNeeded = { _, _ in true }
        let model = AppModel(
            defaults: defaults,
            scheduleAutomaticUpdateCheck: false,
            credentialStore: store
        )
        model.draftProfile.baseURL = "https://gateway.example/v1"

        model.testEndpoint()

        XCTAssertEqual(loadCount, 0)
        XCTAssertTrue(model.statusMessage.contains("Repair Keychain once"))
        XCTAssertFalse(model.isBusy)
    }

    @MainActor
    func testSuccessfulRepairRefreshesActualMigrationState() {
        let suiteName = "MigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var needsRepair = true
        var store = makeCredentialStore(presence: .protected)
        store.migrationNeeded = { _, _ in needsRepair }
        store.migrate = { _, _ in
            needsRepair = false
            return .init(migratedProfileCount: 1, unresolvedProfileCount: 0, migratedLegacyKey: false)
        }
        let model = AppModel(
            defaults: defaults,
            scheduleAutomaticUpdateCheck: false,
            credentialStore: store
        )
        XCTAssertTrue(model.credentialMigrationAvailable)

        model.migrateSavedCredentials()

        XCTAssertFalse(model.credentialMigrationAvailable)
        XCTAssertTrue(model.statusMessage.contains("Keychain repair complete"))
    }

    @MainActor
    func testRepairFailurePersistsPendingStateAcrossRestart() {
        let suiteName = "MigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var store = makeCredentialStore(presence: .protected)
        store.migrationNeeded = { _, _ in true }
        store.migrate = { _, _ in throw TestFailure.expected }
        let model = AppModel(defaults: defaults, scheduleAutomaticUpdateCheck: false, credentialStore: store)

        model.migrateSavedCredentials()

        store.migrationNeeded = { _, _ in false }
        let relaunched = AppModel(defaults: defaults, scheduleAutomaticUpdateCheck: false, credentialStore: store)
        XCTAssertTrue(relaunched.credentialMigrationAvailable)
    }

    @MainActor
    func testSavingNewKeyIsBlockedWhileAnyLegacyCredentialNeedsRepair() {
        let suiteName = "MigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var saveCount = 0
        var store = makeCredentialStore(presence: .protected)
        store.migrationNeeded = { _, _ in true }
        store.save = { _, _ in saveCount += 1 }
        let model = AppModel(defaults: defaults, scheduleAutomaticUpdateCheck: false, credentialStore: store)
        model.draftProfile.baseURL = "https://gateway.example/v1"
        model.apiKey = "new-secret"

        XCTAssertFalse(model.saveSelectedProfile())
        XCTAssertEqual(saveCount, 0)
        XCTAssertTrue(model.statusMessage.contains("Repair Keychain once"))
    }

    func testMigrationDoesNotPersistOrDeleteLegacyKeyWhenNewKeySaveFails() {
        var persisted = false
        var removedLegacy = false
        XCTAssertThrowsError(try LegacyProfileMigrator.migrate(
            saveAndVerifyKey: { throw TestFailure.expected },
            persistProfiles: { persisted = true; return true },
            removeLegacyKey: { removedLegacy = true }
        ))
        XCTAssertFalse(persisted)
        XCTAssertFalse(removedLegacy)
    }

    func testMigrationKeepsLegacyKeyWhenProfilePersistenceFails() {
        var removedLegacy = false
        XCTAssertThrowsError(try LegacyProfileMigrator.migrate(
            saveAndVerifyKey: { "legacy-secret" },
            persistProfiles: { false },
            removeLegacyKey: { removedLegacy = true }
        ))
        XCTAssertFalse(removedLegacy)
    }

    func testMigrationRemainsSuccessfulWhenLegacyCleanupFails() throws {
        let migrated = try LegacyProfileMigrator.migrate(
            saveAndVerifyKey: { "legacy-secret" },
            persistProfiles: { true },
            removeLegacyKey: { throw TestFailure.expected }
        )
        XCTAssertEqual(migrated, "legacy-secret")
    }

    func testVaultTransactionRemovesNewVaultWhenVerificationFails() {
        var storedValue: String?

        XCTAssertThrowsError(try KeychainMigrationTransaction.commit(
            currentVaultExisted: false,
            save: { storedValue = "new-vault" },
            verify: { false },
            restore: { XCTFail("A newly created vault must be removed, not restored") },
            remove: { storedValue = nil },
            verifyRollback: { storedValue == nil }
        ))

        XCTAssertNil(storedValue)
    }

    func testVaultTransactionRestoresExistingVaultWhenVerificationThrows() {
        var storedValue: String? = "original-vault"

        XCTAssertThrowsError(try KeychainMigrationTransaction.commit(
            currentVaultExisted: true,
            save: { storedValue = "replacement-vault" },
            verify: { throw TestFailure.expected },
            restore: { storedValue = "original-vault" },
            remove: { XCTFail("An existing vault must be restored, not removed") },
            verifyRollback: { storedValue == "original-vault" }
        ))

        XCTAssertEqual(storedValue, "original-vault")
    }

    func testVaultTransactionReportsVerificationAndRollbackFailure() {
        XCTAssertThrowsError(try KeychainMigrationTransaction.commit(
            currentVaultExisted: false,
            save: {},
            verify: { false },
            restore: {},
            remove: { throw TestFailure.expected },
            verifyRollback: { false }
        )) { error in
            guard case KeychainMigrationError.verificationAndRollbackFailed = error else {
                return XCTFail("Expected the combined verification/rollback error, got \(error)")
            }
        }
    }

    func testEmptyVaultIsPersistedAsTombstoneAndSuppressesLegacyResidue() throws {
        var persistedData: Data?
        try KeychainVaultPersistence.persist(keys: [:]) { persistedData = $0 }

        let payload = try JSONDecoder().decode(
            KeychainVaultPersistence.Payload.self,
            from: XCTUnwrap(persistedData)
        )
        XCTAssertTrue(payload.keys.isEmpty)
        XCTAssertFalse(KeychainMigrationPolicy.requiresRepair(
            currentVault: .present,
            legacyMayExist: true
        ))
        XCTAssertTrue(KeychainMigrationPolicy.requiresRepair(
            currentVault: .absent,
            legacyMayExist: true
        ))
    }
}

    @MainActor
    func testReplacingAnUnloadedKeyInvalidatesPreviousModelVerification() {
        let suiteName = "MigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            defaults: defaults,
            scheduleAutomaticUpdateCheck: false,
            credentialStore: makeCredentialStore(presence: .present)
        )
        model.draftProfile.baseURL = "https://gateway.example/v1"
        model.draftProfile.models = [
            GatewayModel(modelID: "verified-model", displayName: "Verified", isVerified: true)
        ]
        XCTAssertTrue(model.saveSelectedProfile())
        XCTAssertTrue(model.draftProfile.models[0].isVerified)

        // The stored key was never loaded, so the field starts empty and a typed
        // value silently replaces a different credential.
        XCTAssertFalse(model.credentialLoaded)
        model.apiKey = "rotated-key"
        XCTAssertTrue(model.saveSelectedProfile())
        XCTAssertFalse(model.draftProfile.models[0].isVerified)
        XCTAssertFalse(model.profiles[0].models[0].isVerified)
    }

    @MainActor
    func testOpenCodeExportOnlyUnlocksCredentialsItActuallyWrites() throws {
        let suiteName = "MigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var loadedProfileIDs: [UUID] = []
        let model = AppModel(
            defaults: defaults,
            scheduleAutomaticUpdateCheck: false,
            credentialStore: makeCredentialStore(
                presence: .present,
                load: { id, _ in loadedProfileIDs.append(id); return "secret-\(id.uuidString.prefix(4))" }
            )
        )
        model.draftProfile.baseURL = "https://exported.example/v1"
        model.draftProfile.models = [
            GatewayModel(modelID: "exported-model", displayName: "Exported", isVerified: true)
        ]
        XCTAssertTrue(model.saveSelectedProfile())
        let exportedID = model.selectedProfileID

        // A second endpoint with no verified model is never written to OpenCode.
        model.addProfile()
        model.draftProfile.baseURL = "https://unverified.example/v1"
        model.draftProfile.models = [GatewayModel(modelID: "unverified-model")]
        XCTAssertTrue(model.saveSelectedProfile())

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockOpenCodeScope-\(UUID().uuidString)/OpenCode", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let exported = OpenCodeIntegration.exportableProfiles(model.profiles)
        XCTAssertEqual(exported.map(\.id), [exportedID])

        loadedProfileIDs.removeAll()
        model.configureOpenCode(
            launch: false,
            directory: directory,
            revealGeneratedConfiguration: false
        )
        XCTAssertEqual(model.statusMessage, "OpenCode configuration generated")
        XCTAssertEqual(loadedProfileIDs, [exportedID])
        let document = try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("opencode.json"))
        ) as? [String: Any]
        let providers = try XCTUnwrap(document?["provider"] as? [String: Any])
        XCTAssertEqual(providers.count, 1)
    }

private func makeCredentialStore(
    presence: KeychainStore.Presence = .absent,
    load: @escaping (UUID, Bool) throws -> String = { _, _ in "" }
) -> CredentialStoreClient {
    CredentialStoreClient(
        presence: { _, _ in presence },
        migrationNeeded: { _, _ in false },
        loadForUserAction: load,
        save: { _, _ in },
        remove: { _ in },
        migrate: { _, _ in .init(migratedProfileCount: 0, unresolvedProfileCount: 0, migratedLegacyKey: false) },
        removeAll: {}
    )
}

private enum TestFailure: Error {
    case expected
}
