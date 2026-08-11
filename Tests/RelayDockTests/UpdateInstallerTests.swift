import XCTest
@testable import RelayDock

final class UpdateInstallerTests: XCTestCase {
    func testRejectsUnsafeReleaseVersions() {
        XCTAssertTrue(UpdateInstaller.isSafeVersion("0.3.1"))
        XCTAssertTrue(UpdateInstaller.isSafeVersion("1.0.0-beta.1"))
        XCTAssertFalse(UpdateInstaller.isSafeVersion("1.0.0/../../evil"))
        XCTAssertFalse(UpdateInstaller.isSafeVersion("1.0.0$(touch bad)"))
    }

    func testRealDMGCanBePreparedWhenRequested() throws {
        guard let dmgPath = ProcessInfo.processInfo.environment["RELAYDOCK_UPDATE_TEST_DMG"] else {
            throw XCTSkip("Set RELAYDOCK_UPDATE_TEST_DMG to run the real DMG integration test")
        }
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockPrepareTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer {
            if FileManager.default.fileExists(atPath: support.path) {
                try? FileManager.default.removeItem(at: support)
            }
        }
        let expectedVersion = ProcessInfo.processInfo.environment["RELAYDOCK_UPDATE_TEST_VERSION"] ?? "0.3.1"
        let prepared = try UpdateInstaller.prepare(
            dmgURL: URL(fileURLWithPath: dmgPath),
            expectedVersion: expectedVersion,
            targetAppURL: support.appendingPathComponent("Applications/RelayDock.app"),
            supportDirectory: support,
            restartApplication: false
        )
        defer { UpdateInstaller.discard(prepared) }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: prepared.launcherURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.mountPoint.appendingPathComponent(".payload/RelayDock.app").path))
    }

    func testParsesMountPointFromHDIUtilPlist() throws {
        let plist: [String: Any] = [
            "system-entities": [
                ["dev-entry": "/dev/disk9"],
                ["mount-point": "/Volumes/RelayDock 0.3.1", "dev-entry": "/dev/disk9s1"]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertEqual(
            try UpdateInstaller.mountPoint(from: data).path,
            "/Volumes/RelayDock 0.3.1"
        )
    }

    func testRejectsMountPlistWithoutMountPoint() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["system-entities": [["dev-entry": "/dev/disk9"]]],
            format: .xml,
            options: 0
        )
        XCTAssertThrowsError(try UpdateInstaller.mountPoint(from: data))
        XCTAssertEqual(UpdateInstaller.deviceEntry(from: data), "/dev/disk9")
    }

    func testLauncherInstallsVerifiesDetachesAndRestarts() {
        let script = UpdateInstaller.makeLauncherScript(
            installerURL: URL(fileURLWithPath: "/Volumes/RelayDock 0.3.1/Install RelayDock.command"),
            mountPoint: URL(fileURLWithPath: "/Volumes/RelayDock 0.3.1"),
            targetAppURL: URL(fileURLWithPath: "/Applications/RelayDock.app"),
            expectedVersion: "0.3.1",
            restartApplication: true
        )
        XCTAssertTrue(script.contains("RELAYDOCK_INSTALL_DIR='/Applications'"))
        XCTAssertTrue(script.contains("RELAYDOCK_OPEN_APP=0"))
        XCTAssertTrue(script.contains("RELAYDOCK_INSTALL_CONFIRM=1"))
        XCTAssertTrue(script.contains("RELAYDOCK_EXPECTED_VERSION='0.3.1'"))
        XCTAssertTrue(script.contains("/usr/libexec/PlistBuddy"))
        XCTAssertTrue(script.contains("hdiutil detach '/Volumes/RelayDock 0.3.1'"))
        XCTAssertTrue(script.contains("pkill -x RelayDock"))
        XCTAssertTrue(script.contains("RelayDock 0.3.1 installed and verified"))
    }

    func testSmokeLauncherCanSkipRestart() {
        let script = UpdateInstaller.makeLauncherScript(
            installerURL: URL(fileURLWithPath: "/tmp/update/Install RelayDock.command"),
            mountPoint: URL(fileURLWithPath: "/tmp/update"),
            targetAppURL: URL(fileURLWithPath: "/tmp/Applications/RelayDock.app"),
            expectedVersion: "0.3.1",
            restartApplication: false
        )
        XCTAssertFalse(script.contains("pkill -x RelayDock"))
        XCTAssertTrue(script.contains("RELAYDOCK_INSTALL_DIR='/tmp/Applications'"))
    }
}
