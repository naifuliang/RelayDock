import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var profiles: [GatewayProfile]
    @Published var selectedProfileID: UUID
    @Published var draftProfile: GatewayProfile
    @Published var apiKey: String
    @Published private(set) var proxyRunning = false
    @Published private(set) var proxyPort: UInt16?
    @Published private(set) var events: [ProxyEvent] = []
    @Published private(set) var statusMessage = "准备就绪"
    @Published private(set) var isBusy = false
    @Published private(set) var availableRelease: GitHubRelease?
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var isDownloadingUpdate = false
    @Published var automaticUpdateChecks: Bool {
        didSet { defaults.set(automaticUpdateChecks, forKey: Self.automaticUpdatesKey) }
    }

    private let defaults = UserDefaults.standard
    private var proxy: ProbeProxy?
    private var activeProxyToken: UUID?
    private var savedAPIKey: String
    private static let profilesKey = "gatewayProfiles.v2"
    private static let legacyProfileKey = "endpointProfile"
    private static let selectedProfileKey = "selectedGatewayProfileID"
    private static let automaticUpdatesKey = "automaticUpdateChecks"
    private static let lastUpdateCheckKey = "lastUpdateCheck"

    init() {
        let defaults = UserDefaults.standard
        let decodedProfiles = defaults.data(forKey: Self.profilesKey)
            .flatMap { try? JSONDecoder().decode([GatewayProfile].self, from: $0) }
        var migratedLegacy = false
        let initialProfiles: [GatewayProfile]
        if let decodedProfiles, !decodedProfiles.isEmpty {
            initialProfiles = decodedProfiles
        } else if let legacyData = defaults.data(forKey: Self.legacyProfileKey),
                  let legacy = try? JSONDecoder().decode(EndpointProfile.self, from: legacyData) {
            initialProfiles = [GatewayProfile.migrated(from: legacy)]
            migratedLegacy = true
        } else {
            initialProfiles = [GatewayProfile(displayName: "Sub2API")]
        }

        profiles = initialProfiles
        let savedID = defaults.string(forKey: Self.selectedProfileKey).flatMap(UUID.init(uuidString:))
        let initialID = initialProfiles.contains(where: { $0.id == savedID }) ? savedID! : initialProfiles[0].id
        selectedProfileID = initialID
        draftProfile = initialProfiles.first(where: { $0.id == initialID }) ?? initialProfiles[0]
        let initialAPIKey = migratedLegacy
            ? KeychainStore.loadLegacyAPIKey()
            : KeychainStore.loadAPIKey(for: initialID)
        apiKey = initialAPIKey
        savedAPIKey = initialAPIKey
        automaticUpdateChecks = defaults.object(forKey: Self.automaticUpdatesKey) as? Bool ?? true

        if migratedLegacy {
            do {
                let migratedKey = try LegacyProfileMigrator.migrate(
                    saveAndVerifyKey: { try KeychainStore.migrateLegacyAPIKey(to: initialID) },
                    persistProfiles: { self.persistProfiles() },
                    removeLegacyKey: { try KeychainStore.removeLegacyAPIKey() }
                )
                apiKey = migratedKey
                savedAPIKey = migratedKey
            } catch {
                statusMessage = "旧配置暂未迁移，将在下次启动重试：\(error.localizedDescription)"
            }
        }
        if automaticUpdateChecks {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                await self?.checkForUpdates(silent: true)
            }
        }
    }

    var cursorInstalled: Bool { CursorLauncher.isInstalled }
    var openCodeInstalled: Bool { OpenCodeIntegration.isInstalled }
    var hasUnsavedProfileChanges: Bool {
        draftProfile != profiles.first(where: { $0.id == selectedProfileID }) || apiKey != savedAPIKey
    }
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var verdict: ProbeVerdict {
        if events.contains(where: { $0.isAnthropic }) { return .directAnthropic }
        if events.contains(where: { $0.host.contains("cursor.sh") || $0.host.contains("cursor.com") }) {
            return .cursorBackendOnly
        }
        return .waiting
    }

    func selectProfile(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        selectedProfileID = id
        draftProfile = profile
        apiKey = KeychainStore.loadAPIKey(for: id)
        savedAPIKey = apiKey
        defaults.set(id.uuidString, forKey: Self.selectedProfileKey)
        statusMessage = "已切换到 \(profile.displayName)"
    }

    func addProfile() {
        let profile = GatewayProfile(displayName: "Gateway \(profiles.count + 1)")
        profiles.append(profile)
        persistProfiles()
        selectProfile(profile.id)
        statusMessage = "已添加新端点"
    }

    func deleteSelectedProfile() {
        guard profiles.count > 1,
              let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) else {
            statusMessage = "至少需要保留一个端点"
            return
        }
        let removed = profiles[index]
        do {
            try KeychainStore.removeAPIKey(for: removed.id)
        } catch {
            statusMessage = "无法删除端点 Keychain 凭据：\(error.localizedDescription)"
            return
        }
        profiles.remove(at: index)
        persistProfiles()
        let next = profiles[min(index, profiles.count - 1)]
        selectProfile(next.id)
        statusMessage = "端点“\(removed.displayName)”已删除"
    }

    @discardableResult
    func saveSelectedProfile() -> Bool {
        do {
            guard let url = EndpointValidator.normalizedURL(from: draftProfile.baseURL) else {
                statusMessage = "端点地址无效；远程地址需要 HTTPS"
                return false
            }
            let name = draftProfile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                statusMessage = "请填写端点名称"
                return false
            }
            let modelIDs = draftProfile.models
                .map { $0.modelID.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard Set(modelIDs).count == modelIDs.count else {
                statusMessage = "同一个端点中不能有重复的模型 ID"
                return false
            }

            draftProfile.displayName = name
            draftProfile.baseURL = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) else { return false }
            profiles[index] = draftProfile
            persistProfiles()
            try KeychainStore.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: selectedProfileID)
            savedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            apiKey = savedAPIKey
            statusMessage = "端点“\(name)”已安全保存"
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    func addModel() {
        draftProfile.models.append(GatewayModel())
    }

    func removeModel(_ id: UUID) {
        draftProfile.models.removeAll { $0.id == id }
    }

    func testEndpoint() {
        guard let base = EndpointValidator.normalizedURL(from: draftProfile.baseURL) else {
            statusMessage = "请先填写有效的 HTTPS 端点"
            return
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = draftProfile
        isBusy = true
        statusMessage = "正在测试模型接口…"

        Task {
            defer { isBusy = false }
            do {
                let url = Self.modelsURL(base: base)
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                if !key.isEmpty {
                    switch profile.provider {
                    case .azureOpenAI:
                        request.setValue(key, forHTTPHeaderField: "api-key")
                    case .anthropic:
                        request.setValue(key, forHTTPHeaderField: "x-api-key")
                        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    case .openAICompatible, .openAIResponses:
                        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    }
                }
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw EndpointError.invalidResponse }
                statusMessage = (200..<300).contains(http.statusCode)
                    ? "端点连接成功（HTTP \(http.statusCode)）"
                    : "端点返回 HTTP \(http.statusCode)"
            } catch {
                statusMessage = "连接失败：\(error.localizedDescription)"
            }
        }
    }

    func configureOpenCode(launch: Bool) {
        if launch {
            do {
                try OpenCodeIntegration.validateLaunchAvailability()
            } catch {
                statusMessage = error.localizedDescription
                return
            }
        }
        guard saveSelectedProfile() else { return }
        do {
            let keys = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, KeychainStore.loadAPIKey(for: $0.id)) })
            let configURL = try OpenCodeIntegration.generateConfiguration(profiles: profiles, apiKeys: keys)
            if launch {
                try OpenCodeIntegration.launch(configURL: configURL)
                statusMessage = "OpenCode 已使用 \(profiles.filter(\.isEnabled).count) 个 RelayDock 端点启动"
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([configURL])
                statusMessage = "OpenCode 配置已生成"
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func checkForUpdates(silent: Bool = false) async {
        if silent,
           let lastCheck = defaults.object(forKey: Self.lastUpdateCheckKey) as? Date,
           Date().timeIntervalSince(lastCheck) < 24 * 60 * 60 { return }
        isCheckingForUpdates = true
        if !silent { statusMessage = "正在检查 GitHub 更新…" }
        defer { isCheckingForUpdates = false }
        do {
            let release = try await GitHubUpdater.fetchLatestRelease()
            defaults.set(Date(), forKey: Self.lastUpdateCheckKey)
            if !release.draft, !release.prerelease,
               VersionComparator.isNewer(release.version, than: currentVersion) {
                availableRelease = release
                statusMessage = "发现新版本 \(release.version)"
            } else if !silent {
                availableRelease = nil
                statusMessage = "RelayDock \(currentVersion) 已是最新版本"
            }
        } catch {
            if !silent { statusMessage = "更新检查失败：\(error.localizedDescription)" }
        }
    }

    func downloadAvailableUpdate() {
        guard let release = availableRelease else { return }
        isDownloadingUpdate = true
        statusMessage = "正在从 GitHub 下载 RelayDock \(release.version)…"
        Task {
            defer { isDownloadingUpdate = false }
            do {
                let fileURL = try await GitHubUpdater.downloadDMG(from: release)
                NSWorkspace.shared.open(fileURL)
                statusMessage = "更新包已下载到 Downloads 并打开"
            } catch {
                statusMessage = "更新下载失败：\(error.localizedDescription)"
            }
        }
    }

    func startProbe() {
        guard proxy == nil, !proxyRunning else { return }
        events.removeAll()
        let token = UUID()
        activeProxyToken = token
        let proxy = ProbeProxy(
            onEvent: { [weak self] event in
                Task { @MainActor in
                    guard self?.activeProxyToken == token else { return }
                    self?.events.insert(event, at: 0)
                    if self?.events.count ?? 0 > 200 { self?.events.removeLast() }
                }
            },
            onState: { [weak self] running, port in
                Task { @MainActor in
                    guard self?.activeProxyToken == token else { return }
                    self?.proxyRunning = running
                    self?.proxyPort = port
                    self?.statusMessage = running ? "探测代理正在监听 127.0.0.1:\(port ?? 0)" : "探测代理已停止"
                }
            }
        )
        self.proxy = proxy
        do {
            try proxy.start()
            statusMessage = "正在启动探测代理…"
        } catch {
            statusMessage = "代理启动失败：\(error.localizedDescription)"
            self.proxy = nil
            activeProxyToken = nil
        }
    }

    func stopProbe() {
        let activeProxy = proxy
        proxy = nil
        activeProxyToken = nil
        proxyRunning = false
        proxyPort = nil
        activeProxy?.stop()
    }

    func launchCursor(restart: Bool) {
        guard proxyRunning, let proxyPort else {
            statusMessage = "请先启动探测代理"
            return
        }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                if restart { try await CursorLauncher.terminate() }
                try CursorLauncher.launch(proxyPort: proxyPort)
                statusMessage = "Cursor 已通过 RelayDock 启动，请发送一条 Anthropic BYOK 消息"
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func clearDiagnostics() {
        events.removeAll()
        statusMessage = "诊断记录已清除"
    }

    func removeLocalData() {
        do {
            stopProbe()
            defaults.removeObject(forKey: Self.profilesKey)
            defaults.removeObject(forKey: Self.legacyProfileKey)
            defaults.removeObject(forKey: Self.selectedProfileKey)
            try KeychainStore.removeAll()
            try OpenCodeIntegration.removeGeneratedFiles()
            let profile = GatewayProfile(displayName: "Sub2API")
            profiles = [profile]
            selectedProfileID = profile.id
            draftProfile = profile
            apiKey = ""
            savedAPIKey = ""
            events.removeAll()
            persistProfiles()
            statusMessage = "RelayDock 端点、OpenCode 配置和钥匙串凭据已清除"
        } catch {
            statusMessage = "清理失败：\(error.localizedDescription)"
        }
    }

    @discardableResult
    private func persistProfiles() -> Bool {
        guard let data = try? JSONEncoder().encode(profiles) else { return false }
        defaults.set(data, forKey: Self.profilesKey)
        return defaults.data(forKey: Self.profilesKey) == data
    }

    private static func modelsURL(base: URL) -> URL {
        let trimmedPath = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmedPath.hasSuffix("v1") { return base.appendingPathComponent("models") }
        return base.appendingPathComponent("v1/models")
    }
}

enum EndpointError: LocalizedError {
    case invalidResponse
    var errorDescription: String? { "端点响应无效" }
}
