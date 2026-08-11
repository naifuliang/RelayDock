import Foundation
import XCTest

final class InstallerContinuityTests: XCTestCase {
    func testReleaseVersionAndBuildArePaired() throws {
        let infoURL = repositoryRoot.appendingPathComponent("support/Info.plist")
        let data = try Data(contentsOf: infoURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "0.5.3")
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "9")
    }

    func testEveryUnsignedDistributionChannelUsesSharedTransactionalInstaller() throws {
        let root = repositoryRoot
        let oneLineInstaller = try String(contentsOf: root.appendingPathComponent("install.sh"))
        let packager = try String(contentsOf: root.appendingPathComponent("scripts/package-release.sh"))
        let installer = try String(contentsOf: root.appendingPathComponent("scripts/install-relaydock.command"))

        XCTAssertTrue(oneLineInstaller.contains("Install RelayDock.command"))
        XCTAssertTrue(oneLineInstaller.contains("RELAYDOCK_INSTALL_CONFIRM=1"))
        XCTAssertFalse(oneLineInstaller.contains("codesign --force"))
        XCTAssertTrue(packager.contains("$ZIP_STAGING_DIR/Install RelayDock.command"))
        XCTAssertTrue(packager.contains("$ZIP_STAGING_DIR/.payload/$APP_NAME.app"))
        XCTAssertTrue(packager.contains("ln -s \".payload/$APP_NAME.app\" \"$STAGING_DIR/$APP_NAME.app\""))
        XCTAssertTrue(packager.contains("/usr/bin/SetFile -P -a V \"$STAGING_DIR/$APP_NAME.app\""))
        XCTAssertFalse(packager.contains("ln -s /Applications"))
        XCTAssertFalse(packager.contains("pkgbuild"))
        XCTAssertTrue(installer.contains("EXISTING_REQUIREMENT"))
        XCTAssertTrue(installer.contains("NEW_REQUIREMENT"))
        XCTAssertTrue(installer.contains("INSTALLED_REQUIREMENT"))
        XCTAssertTrue(installer.contains("the previous RelayDock app was restored"))
        XCTAssertTrue(installer.contains("RELAYDOCK_TEST_FAIL_AFTER_REPLACE"))
        XCTAssertTrue(installer.contains("approved-developer-identity"))
        XCTAssertTrue(installer.contains("Type the Team ID"))
        XCTAssertTrue(installer.contains("exec {terminal_fd}<>/dev/tty"))
        XCTAssertTrue(installer.contains("REPAIR_REPLY=\"$(read_terminal_response"))
        XCTAssertTrue(installer.contains("ADOPTION_REPLY=\"$(read_terminal_response"))
        XCTAssertFalse(installer.contains("read \"REPAIR_REPLY?"))
        XCTAssertFalse(installer.contains("read \"ADOPTION_REPLY?"))
    }

    func testSigningHelperFailsClosedAndRequiresExplicitRepair() throws {
        let helper = try String(contentsOf: repositoryRoot.appendingPathComponent("scripts/local-sign-relaydock.sh"))
        XCTAssertTrue(helper.contains("RELAYDOCK_REPAIR_SIGNING_IDENTITY"))
        XCTAssertTrue(helper.contains("designated-requirement"))
        XCTAssertTrue(helper.contains("signing-probe"))
        XCTAssertTrue(helper.contains("$APP_PATH/Contents/MacOS/RelayDock"))
        XCTAssertFalse(helper.contains("/usr/bin/true"))
        XCTAssertTrue(helper.contains("exit 4"))
        XCTAssertTrue(helper.contains("FILTERED_KEYCHAINS"))
        XCTAssertTrue(helper.contains("list-keychains -d user -s"))
        XCTAssertTrue(helper.contains("REMOVED_SEARCH_ENTRY=1"))
    }

    func testUninstallerQueriesBridgeCertificatesInExplicitDefaultKeychain() throws {
        let uninstaller = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/uninstall-relaydock.command")
        )
        XCTAssertTrue(uninstaller.contains("security default-keychain -d user"))
        XCTAssertTrue(uninstaller.contains("\"$DEFAULT_USER_KEYCHAIN\""))
        XCTAssertTrue(uninstaller.contains("find-certificate -a -c \"RelayDock Anthropic Bridge\" -p"))
    }

    func testExecutableSigningTransitionPolicy() throws {
        XCTAssertEqual(try runPolicy("none", "", "local", "local-a", "0"), 0)
        XCTAssertEqual(try runPolicy("adhoc", "", "developer", "TEAM-A|app.relaydock.mac", "0"), 0)
        XCTAssertEqual(try runPolicy("local", "local-a", "local", "local-a", "0"), 0)
        XCTAssertEqual(try runPolicy("local", "local-a", "local", "local-b", "0"), 4)
        XCTAssertEqual(try runPolicy("local", "local-a", "local", "local-b", "1"), 0)
        XCTAssertEqual(try runPolicy("local", "local-a", "developer", "TEAM-A|app.relaydock.mac", "0"), 4)
        XCTAssertEqual(try runPolicy("local", "local-a", "developer", "TEAM-A|app.relaydock.mac", "0", "1"), 0)
        XCTAssertEqual(try runPolicy("developer", "TEAM-A|app.relaydock.mac", "local", "local-a", "1"), 4)
        XCTAssertEqual(try runPolicy("developer", "TEAM-A|app.relaydock.mac", "developer", "TEAM-A|app.relaydock.mac", "0"), 0)
        XCTAssertEqual(try runPolicy("developer", "TEAM-A|app.relaydock.mac", "developer", "TEAM-B|app.relaydock.mac", "0"), 4)
        XCTAssertEqual(try runPolicy("developer", "TEAM-A|app.relaydock.mac", "developer", "TEAM-A|other.bundle", "0"), 4)
    }

    private func runPolicy(_ arguments: String...) throws -> Int32 {
        let process = Process()
        process.executableURL = repositoryRoot.appendingPathComponent("scripts/verify-signing-transition.sh")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
