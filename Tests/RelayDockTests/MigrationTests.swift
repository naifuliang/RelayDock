import XCTest
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
        let value = query[kSecUseAuthenticationUI as String]

        XCTAssertNotNil(value)
        XCTAssertTrue(CFEqual(value as CFTypeRef?, kSecUseAuthenticationUIFail))
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

private enum TestFailure: Error {
    case expected
}
