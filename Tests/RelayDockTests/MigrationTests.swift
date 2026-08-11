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
    func testLegacyCredentialTargetSurvivesRestartWithoutReadingSecret() throws {
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
        XCTAssertEqual(loadCount, 1)
        XCTAssertTrue(includedLegacyKey)
        XCTAssertEqual(relaunched.apiKey, "legacy-secret")
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
