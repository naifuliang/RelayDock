import Foundation

struct PreparedUpdate {
    let launcherURL: URL
    let mountPoint: URL
}

enum UpdateInstaller {
    static var defaultSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RelayDock/Update", isDirectory: true)
    }

    static func prepare(
        dmgURL: URL,
        expectedVersion: String,
        targetAppURL: URL = URL(fileURLWithPath: "/Applications/RelayDock.app"),
        supportDirectory: URL = defaultSupportDirectory,
        restartApplication: Bool = true
    ) throws -> PreparedUpdate {
        guard isSafeVersion(expectedVersion) else { throw UpdateInstallError.invalidVersion }
        let mountPoint = try mount(dmgURL: dmgURL)
        do {
            let sourceApp = mountPoint.appendingPathComponent(".payload/RelayDock.app", isDirectory: true)
            let installer = mountPoint.appendingPathComponent("Install RelayDock.command")
            let signingHelper = mountPoint.appendingPathComponent("local-sign-relaydock.sh")
            let identityPolicy = mountPoint.appendingPathComponent("verify-signing-transition.sh")
            guard FileManager.default.fileExists(atPath: sourceApp.path),
                  FileManager.default.isExecutableFile(atPath: installer.path),
                  FileManager.default.isExecutableFile(atPath: signingHelper.path),
                  FileManager.default.isExecutableFile(atPath: identityPolicy.path) else {
                throw UpdateInstallError.invalidImageContents
            }
            guard try appVersion(at: sourceApp) == expectedVersion else {
                throw UpdateInstallError.versionMismatch
            }
            try verifyCodeSignature(appURL: sourceApp)

            try FileManager.default.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let launcherURL = supportDirectory.appendingPathComponent("Install RelayDock \(expectedVersion).command")
            let script = makeLauncherScript(
                installerURL: installer,
                mountPoint: mountPoint,
                targetAppURL: targetAppURL,
                expectedVersion: expectedVersion,
                restartApplication: restartApplication
            )
            try Data(script.utf8).write(to: launcherURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcherURL.path)
            return PreparedUpdate(launcherURL: launcherURL, mountPoint: mountPoint)
        } catch {
            try? detach(mountPoint: mountPoint)
            throw error
        }
    }

    static func makeLauncherScript(
        installerURL: URL,
        mountPoint: URL,
        targetAppURL: URL,
        expectedVersion: String,
        restartApplication: Bool
    ) -> String {
        let installDirectory = targetAppURL.deletingLastPathComponent()
        let restart = restartApplication ? """
        /usr/bin/pkill -x RelayDock 2>/dev/null || true
        /bin/sleep 1
        /usr/bin/open \(shellQuote(targetAppURL.path))
        """ : ""
        return """
        #!/bin/zsh
        set -euo pipefail

        cleanup() {
            /usr/bin/hdiutil detach \(shellQuote(mountPoint.path)) >/dev/null 2>&1 || true
        }
        trap cleanup EXIT

        RELAYDOCK_INSTALL_DIR=\(shellQuote(installDirectory.path)) RELAYDOCK_OPEN_APP=0 RELAYDOCK_INSTALL_CONFIRM=1 RELAYDOCK_EXPECTED_VERSION=\(shellQuote(expectedVersion)) /bin/zsh \(shellQuote(installerURL.path))
        INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \(shellQuote(targetAppURL.appendingPathComponent("Contents/Info.plist").path)))"
        if [[ "$INSTALLED_VERSION" != \(shellQuote(expectedVersion)) ]]; then
            echo \(shellQuote("Update verification failed: expected \(expectedVersion)."))
            echo "Found $INSTALLED_VERSION."
            exit 1
        fi
        echo \(shellQuote("RelayDock \(expectedVersion) installed and verified."))
        \(restart)
        """
    }

    static func discard(_ prepared: PreparedUpdate) {
        try? detach(mountPoint: prepared.mountPoint)
    }

    static func mountPoint(from plistData: Data) throws -> URL {
        guard let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let path = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateInstallError.mountFailed
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func deviceEntry(from plistData: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        return entities.compactMap { $0["dev-entry"] as? String }.first
    }

    static func isSafeVersion(_ version: String) -> Bool {
        guard !version.isEmpty, version.count <= 64 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return version.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func mount(dmgURL: URL) throws -> URL {
        let result = try run(
            executable: "/usr/bin/hdiutil",
            arguments: ["attach", "-readonly", "-noautoopen", "-nobrowse", "-plist", dmgURL.path]
        )
        guard result.status == 0 else { throw UpdateInstallError.mountFailed }
        do {
            return try mountPoint(from: result.stdout)
        } catch {
            if let device = deviceEntry(from: result.stdout) {
                try? detach(target: device)
            }
            throw error
        }
    }

    private static func detach(mountPoint: URL) throws {
        try detach(target: mountPoint.path)
    }

    private static func detach(target: String) throws {
        let result = try run(executable: "/usr/bin/hdiutil", arguments: ["detach", target])
        guard result.status == 0 else { throw UpdateInstallError.detachFailed }
    }

    private static func appVersion(at appURL: URL) throws -> String {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: infoURL)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String else {
            throw UpdateInstallError.invalidImageContents
        }
        return version
    }

    private static func verifyCodeSignature(appURL: URL) throws {
        let result = try run(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", "--verbose=2", appURL.path]
        )
        guard result.status == 0 else { throw UpdateInstallError.invalidSignature }
    }

    private static func run(executable: String, arguments: [String]) throws -> (status: Int32, stdout: Data) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, stdout)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum UpdateInstallError: LocalizedError {
    case invalidVersion
    case mountFailed
    case invalidImageContents
    case versionMismatch
    case invalidSignature
    case detachFailed
    case launcherFailed

    var errorDescription: String? {
        switch self {
        case .invalidVersion: return L10n.t("The GitHub Release version string is unsafe; installation was stopped.", zh: "GitHub Release 版本字符串不安全，已停止安装。")
        case .mountFailed: return L10n.t("Could not mount the downloaded update disk image.", zh: "无法挂载已下载的更新磁盘映像。")
        case .invalidImageContents: return L10n.t("The update disk image is missing the RelayDock app or installer script.", zh: "更新磁盘映像缺少 RelayDock App 或安装脚本。")
        case .versionMismatch: return L10n.t("The version inside the update package does not match the GitHub Release.", zh: "更新包内版本与 GitHub Release 版本不一致。")
        case .invalidSignature: return L10n.t("Code signature verification failed for the app inside the update package.", zh: "更新包内 App 的代码签名校验失败。")
        case .detachFailed: return L10n.t("Could not unmount the update disk image.", zh: "无法卸载更新磁盘映像。")
        case .launcherFailed: return L10n.t("Could not open the RelayDock update installer.", zh: "无法打开 RelayDock 更新安装器。")
        }
    }
}
