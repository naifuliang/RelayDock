import AppKit
import Foundation

enum OpenCodeIntegration {
    private static let desktopBundleIdentifier = "ai.opencode.desktop"

    static var configurationDirectory: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appendingPathComponent("RelayDock/OpenCode", isDirectory: true)
    }

    static var isInstalled: Bool { executableURL != nil }

    static func validateLaunchAvailability() throws {
        guard let executableURL else { throw OpenCodeError.notInstalled }
        if executableURL.path.contains(".app/Contents/MacOS/"),
           !NSRunningApplication.runningApplications(withBundleIdentifier: desktopBundleIdentifier).isEmpty {
            throw OpenCodeError.desktopAlreadyRunning
        }
    }

    /// The endpoints a generated configuration will contain. Callers use this to
    /// unlock exactly the credentials the export needs and nothing else.
    static func exportableProfiles(_ profiles: [GatewayProfile]) -> [GatewayProfile] {
        profiles.filter { profile in
            profile.isEnabled && profile.models.contains(where: {
                $0.isEnabled && $0.isVerified && !$0.modelID.trimmed.isEmpty
            })
        }
    }

    static func generateConfiguration(
        profiles: [GatewayProfile],
        apiKeys: [UUID: String],
        directory: URL = configurationDirectory
    ) throws -> URL {
        let enabledProfiles = exportableProfiles(profiles)
        guard !enabledProfiles.isEmpty else { throw OpenCodeError.noEnabledModels }

        let fileManager = FileManager.default
        let parentDirectory = directory.deletingLastPathComponent()
        let stagingDirectory = parentDirectory.appendingPathComponent(
            ".OpenCode.staging.\(UUID().uuidString)", isDirectory: true
        )
        let backupDirectory = parentDirectory.appendingPathComponent(
            ".OpenCode.backup.\(UUID().uuidString)", isDirectory: true
        )
        try fileManager.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try cleanupPendingSensitiveBackups(parentDirectory: parentDirectory)
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var stagingMoved = false
        defer {
            if !stagingMoved, fileManager.fileExists(atPath: stagingDirectory.path) {
                try? fileManager.removeItem(at: stagingDirectory)
            }
        }
        let keysDirectory = stagingDirectory.appendingPathComponent("keys", isDirectory: true)
        try fileManager.createDirectory(
            at: keysDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var providers: [String: Any] = [:]
        for profile in enabledProfiles {
            guard let normalizedURL = EndpointValidator.normalizedURL(from: profile.baseURL) else {
                throw OpenCodeError.invalidEndpoint(profile.displayName)
            }

            let openCodeBaseURL = profile.provider == .azureOpenAI
                ? normalizedURL
                : EndpointValidator.versionedAPIRoot(normalizedURL)
            var options: [String: Any] = [
                "baseURL": openCodeBaseURL.absoluteString
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ]
            let apiKey = apiKeys[profile.id]?.trimmed ?? ""
            if !apiKey.isEmpty {
                let keyName = "\(profile.id.uuidString.lowercased()).key"
                let stagedKeyURL = keysDirectory.appendingPathComponent(keyName)
                try Data(apiKey.utf8).write(to: stagedKeyURL, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedKeyURL.path)
                options["apiKey"] = "{file:./keys/\(keyName)}"
                if profile.provider == .anthropic,
                   EndpointValidator.isThirdPartyAnthropicGateway(normalizedURL) {
                    let bearerName = "\(profile.id.uuidString.lowercased()).bearer"
                    let stagedBearerURL = keysDirectory.appendingPathComponent(bearerName)
                    try Data("Bearer \(apiKey)".utf8).write(to: stagedBearerURL, options: .atomic)
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: stagedBearerURL.path
                    )
                    options["headers"] = [
                        "Authorization": "{file:./keys/\(bearerName)}"
                    ]
                }
            }
            if profile.provider == .azureOpenAI {
                options["apiVersion"] = profile.azureAPIVersion.trimmed.isEmpty ? "v1" : profile.azureAPIVersion.trimmed
                options["useDeploymentBasedUrls"] = profile.azureDeploymentBasedURLs
            }

            var models: [String: Any] = [:]
            for model in profile.models where model.isEnabled && model.isVerified && !model.modelID.trimmed.isEmpty {
                let modelID = model.modelID.trimmed
                let displayName = model.displayName.trimmed.isEmpty ? modelID : model.displayName.trimmed
                models[modelID] = ["name": displayName]
            }

            providers[profile.providerID] = [
                "npm": profile.provider.openCodePackage,
                "name": profile.displayName.trimmed,
                "options": options,
                "models": models
            ]
        }

        let document: [String: Any] = [
            "$schema": "https://opencode.ai/config.json",
            "provider": providers
        ]
        // OpenCode substitutes `{file:...}` tokens in the raw JSON text before
        // parsing it. Escaped slashes (`\/`) therefore become literal backslashes
        // in its path resolver. Keep slash characters unescaped and use paths
        // relative to this generated config directory.
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        _ = try JSONSerialization.jsonObject(with: data)
        let stagedConfigURL = stagingDirectory.appendingPathComponent("opencode.json")
        try data.write(to: stagedConfigURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedConfigURL.path)

        let hadExistingConfiguration = fileManager.fileExists(atPath: directory.path)
        if hadExistingConfiguration {
            try fileManager.moveItem(at: directory, to: backupDirectory)
        }
        do {
            try fileManager.moveItem(at: stagingDirectory, to: directory)
            stagingMoved = true
        } catch {
            if hadExistingConfiguration, !fileManager.fileExists(atPath: directory.path) {
                try? fileManager.moveItem(at: backupDirectory, to: directory)
            }
            throw error
        }
        if hadExistingConfiguration, fileManager.fileExists(atPath: backupDirectory.path) {
            do {
                try fileManager.removeItem(at: backupDirectory)
            } catch {
                let cleanupDirectory = parentDirectory.appendingPathComponent(
                    ".OpenCode.cleanup.\(UUID().uuidString)", isDirectory: true
                )
                do {
                    try fileManager.moveItem(at: backupDirectory, to: cleanupDirectory)
                    throw OpenCodeError.sensitiveBackupCleanupFailed(cleanupDirectory.path)
                } catch let cleanupError as OpenCodeError {
                    throw cleanupError
                } catch {
                    throw OpenCodeError.sensitiveBackupCleanupFailed(backupDirectory.path)
                }
            }
        }
        return directory.appendingPathComponent("opencode.json")
    }

    static func launch(configURL: URL, directory: URL = configurationDirectory) throws {
        try validateLaunchAvailability()
        guard let executableURL else { throw OpenCodeError.notInstalled }
        let launcherURL = directory.appendingPathComponent("Launch OpenCode.command")
        let launchCommand: String
        if executableURL.path.contains(".app/Contents/MacOS/") {
            launchCommand = "exec /usr/bin/open -n -a 'OpenCode' --env \(shellQuote("OPENCODE_CONFIG=\(configURL.path)"))"
        } else {
            launchCommand = "export OPENCODE_CONFIG=\(shellQuote(configURL.path))\nexec \(shellQuote(executableURL.path))"
        }
        let script = """
        #!/bin/zsh
        \(launchCommand)
        """
        try Data(script.utf8).write(to: launcherURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcherURL.path)
        guard NSWorkspace.shared.open(launcherURL) else { throw OpenCodeError.launchFailed }
    }

    static func removeGeneratedFiles() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: configurationDirectory.path) {
            try fileManager.removeItem(at: configurationDirectory)
        }
    }

    static func cleanupPendingSensitiveBackups(
        parentDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: parentDirectory.path) else { return }
        let entries = try fileManager.contentsOfDirectory(
            at: parentDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for entry in entries where entry.lastPathComponent.hasPrefix(".OpenCode.cleanup.") {
            do {
                try fileManager.removeItem(at: entry)
            } catch {
                throw OpenCodeError.sensitiveBackupCleanupFailed(entry.path)
            }
        }
    }

    private static var executableURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".opencode/bin/opencode"),
            home.appendingPathComponent(".local/bin/opencode"),
            URL(fileURLWithPath: "/opt/homebrew/bin/opencode"),
            URL(fileURLWithPath: "/usr/local/bin/opencode"),
            URL(fileURLWithPath: "/usr/bin/opencode"),
            URL(fileURLWithPath: "/Applications/OpenCode.app/Contents/MacOS/OpenCode"),
            URL(fileURLWithPath: "/Applications/OpenCode.app/Contents/MacOS/opencode")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum OpenCodeError: LocalizedError {
    case noEnabledModels
    case invalidEndpoint(String)
    case notInstalled
    case desktopAlreadyRunning
    case launchFailed
    case sensitiveBackupCleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .noEnabledModels:
            return "请至少测试并启用一个可用模型。"
        case let .invalidEndpoint(name):
            return "端点“\(name)”的地址无效。"
        case .notInstalled:
            return "未找到 OpenCode。支持 OpenCode.app、~/.opencode/bin、~/.local/bin 与 Homebrew。"
        case .desktopAlreadyRunning:
            return "OpenCode 正在运行。请先完全退出 OpenCode，再点击“配置并启动”。"
        case .launchFailed:
            return "无法打开 OpenCode 启动器。"
        case let .sensitiveBackupCleanupFailed(path):
            return "新配置已写入，但包含旧 API Key 的备份未能删除：\(path)。RelayDock 已停止启动 OpenCode，请先安全删除该目录。"
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
