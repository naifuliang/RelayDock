import XCTest
@testable import RelayDock

final class MigrationTests: XCTestCase {
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
