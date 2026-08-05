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
    @Published private(set) var updateInstallerWasOpened = false
    @Published private(set) var updateCheckResult: UpdateCheckResult = .idle
    @Published private(set) var modelProbeStates: [UUID: ModelProbeState] = [:]
    @Published var automaticUpdateChecks: Bool {
        didSet { defaults.set(automaticUpdateChecks, forKey: Self.automaticUpdatesKey) }
    }

    private let defaults: UserDefaults
    private var proxy: ProbeProxy?
    private var activeProxyToken: UUID?
    private var catalogTask: Task<Void, Never>?
    private var modelTestTask: Task<Void, Never>?
    private var endpointOperationToken: UUID?
    private var savedAPIKey: String
    private static let profilesKey = "gatewayProfiles.v2"
    private static let legacyProfileKey = "endpointProfile"
    private static let selectedProfileKey = "selectedGatewayProfileID"
    private static let automaticUpdatesKey = "automaticUpdateChecks"
    private static let lastUpdateCheckKey = "lastUpdateCheck"
    private static let lastUpdateOutcomeKey = "lastUpdateOutcome"
    private static let lastCheckedAppVersionKey = "lastCheckedAppVersion"

    init(defaults: UserDefaults = .standard, scheduleAutomaticUpdateCheck: Bool = true) {
        self.defaults = defaults
        #if DEBUG
        if ProcessInfo.processInfo.environment["RELAYDOCK_UI_PREVIEW"] == "1" {
            let first = GatewayProfile(
                displayName: "Gateway 1",
                provider: .openAICompatible,
                baseURL: "https://api.example.com/v1",
                models: [
                    GatewayModel(modelID: "gpt-5", displayName: "GPT-5"),
                    GatewayModel(modelID: "gpt-4.1", displayName: "GPT-4.1")
                ]
            )
            let second = GatewayProfile(
                displayName: "Anthropic",
                provider: .anthropic,
                baseURL: "https://api.anthropic.com/v1",
                models: [GatewayModel(modelID: "claude-sonnet", displayName: "Claude Sonnet")]
            )
            profiles = [first, second]
            selectedProfileID = first.id
            draftProfile = first
            apiKey = ""
            savedAPIKey = ""
            automaticUpdateChecks = false
            return
        }
        #endif

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
            initialProfiles = [GatewayProfile()]
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
        if automaticUpdateChecks && scheduleAutomaticUpdateCheck {
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
        cancelEndpointOperations()
        selectedProfileID = id
        draftProfile = profile
        apiKey = KeychainStore.loadAPIKey(for: id)
        savedAPIKey = apiKey
        defaults.set(id.uuidString, forKey: Self.selectedProfileKey)
        statusMessage = "已切换到 \(profile.displayName)"
    }

    func discardSelectedProfileChanges() {
        guard let profile = profiles.first(where: { $0.id == selectedProfileID }) else { return }
        cancelEndpointOperations()
        draftProfile = profile
        apiKey = savedAPIKey
        statusMessage = "已放弃未保存的更改"
    }

    func addProfile() {
        cancelEndpointOperations()
        let profile = GatewayProfile(displayName: "Gateway \(profiles.count + 1)")
        profiles.append(profile)
        persistProfiles()
        selectProfile(profile.id)
        statusMessage = "已添加新端点"
    }

    func addProfile(from preset: EndpointPreset) {
        cancelEndpointOperations()
        let shouldReplacePristineDefault = profiles.count == 1
            && profiles[0].isPristineDefault
            && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && savedAPIKey.isEmpty
        let profile: GatewayProfile
        if shouldReplacePristineDefault {
            profile = preset.makeProfile(id: profiles[0].id)
            profiles[0] = profile
        } else {
            profile = preset.makeProfile()
            profiles.append(profile)
        }
        persistProfiles()
        selectProfile(profile.id)
        statusMessage = "已添加 \(preset.profileName)；请填写服务商 API Key 后同步模型"
    }

    func deleteSelectedProfile() {
        cancelEndpointOperations()
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
        guard saveSelectedProfile() else { return }
        guard !(draftProfile.provider == .azureOpenAI && draftProfile.azureDeploymentBasedURLs) else {
            statusMessage = "Azure 旧版 deployment 模式请手动添加 deployment ID"
            return
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = draftProfile
        cancelEndpointOperations()
        let operationToken = UUID()
        endpointOperationToken = operationToken
        isBusy = true
        statusMessage = "正在测试模型接口…"

        catalogTask?.cancel()
        catalogTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if endpointOperationToken == operationToken {
                    isBusy = false
                    catalogTask = nil
                    endpointOperationToken = nil
                }
            }
            do {
                var discoveredModelIDs: [String] = []
                var afterID: String?
                var pageCount = 0
                repeat {
                    let request = try ModelAPIRequestFactory.catalog(profile: profile, apiKey: key, afterID: afterID)
                    let (data, response) = try await URLSession.shared.data(for: request)
                    try Task.checkCancellation()
                    guard endpointOperationToken == operationToken else { return }
                    guard let http = response as? HTTPURLResponse else { throw EndpointError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else {
                        statusMessage = "端点返回 HTTP \(http.statusCode)"
                        return
                    }
                    discoveredModelIDs.append(contentsOf: ModelCatalogParser.modelIDs(from: data))
                    afterID = profile.provider == .anthropic ? ModelCatalogParser.nextCursor(from: data) : nil
                    pageCount += 1
                } while afterID != nil && pageCount < 20
                var seenModelIDs = Set<String>()
                discoveredModelIDs = discoveredModelIDs.filter { seenModelIDs.insert($0).inserted }
                if discoveredModelIDs.isEmpty {
                    statusMessage = "连接成功，但没有识别到文本生成模型"
                } else {
                    guard selectedProfileID == profile.id else { return }
                    applyDiscoveredModels(discoveredModelIDs)
                    statusMessage = "连接成功，已获取 \(discoveredModelIDs.count) 个文本生成模型"
                }
            } catch {
                guard endpointOperationToken == operationToken else { return }
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    statusMessage = "模型同步已取消"
                } else {
                    statusMessage = "连接失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func testAllModels() {
        guard saveSelectedProfile() else { return }
        let routes = draftProfile.models.filter { $0.isEnabled && !$0.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !routes.isEmpty else {
            statusMessage = "请先获取或添加至少一个已启用模型"
            return
        }
        let profile = draftProfile
        let key = apiKey
        cancelEndpointOperations()
        let operationToken = UUID()
        endpointOperationToken = operationToken
        modelProbeStates = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, .testing) })
        isBusy = true
        statusMessage = "正在逐个测试 \(routes.count) 个模型…"

        modelTestTask?.cancel()
        modelTestTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if endpointOperationToken == operationToken {
                    isBusy = false
                    modelTestTask = nil
                    endpointOperationToken = nil
                }
            }
            var availableCount = 0
            for route in routes {
                guard !Task.isCancelled else {
                    if endpointOperationToken == operationToken { statusMessage = "模型验证已取消" }
                    return
                }
                do {
                    let modelID = route.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
                    let request = try ModelAPIRequestFactory.probe(
                        profile: profile,
                        modelID: modelID,
                        apiKey: key
                    )
                    var (responseData, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse,
                       Self.shouldRetryLegacyTokenParameter(data: responseData, statusCode: http.statusCode),
                       let fallback = try ModelAPIRequestFactory.legacyTokenFallback(
                           profile: profile, modelID: modelID, apiKey: key
                       ) {
                        (responseData, response) = try await URLSession.shared.data(for: fallback)
                    }
                    try Task.checkCancellation()
                    guard endpointOperationToken == operationToken else { return }
                    guard let http = response as? HTTPURLResponse else { throw EndpointError.invalidResponse }
                    if (200..<300).contains(http.statusCode) {
                        modelProbeStates[route.id] = .available
                        availableCount += 1
                    } else {
                        modelProbeStates[route.id] = .failed("HTTP \(http.statusCode)")
                    }
                } catch {
                    guard endpointOperationToken == operationToken else { return }
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                        statusMessage = "模型验证已取消"
                        return
                    }
                    modelProbeStates[route.id] = .failed(error.localizedDescription)
                }
            }
            statusMessage = "模型测试完成：\(availableCount)/\(routes.count) 可用"
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
        guard !isCheckingForUpdates else { return }
        let lastCheck = defaults.object(forKey: Self.lastUpdateCheckKey) as? Date
        if silent, GitHubUpdater.shouldSkipAutomaticCheck(
            lastCheck: lastCheck,
            lastOutcome: defaults.string(forKey: Self.lastUpdateOutcomeKey),
            lastCheckedAppVersion: defaults.string(forKey: Self.lastCheckedAppVersionKey),
            currentVersion: currentVersion
        ), let lastCheck {
            updateCheckResult = .upToDate(lastCheck)
            return
        }
        isCheckingForUpdates = true
        updateCheckResult = .checking
        if !silent { statusMessage = "正在检查 GitHub 更新…" }
        defer { isCheckingForUpdates = false }
        do {
            let release = try await GitHubUpdater.fetchLatestRelease()
            let checkedAt = Date()
            defaults.set(checkedAt, forKey: Self.lastUpdateCheckKey)
            if !release.draft, !release.prerelease,
               VersionComparator.isNewer(release.version, than: currentVersion) {
                availableRelease = release
                updateCheckResult = .updateAvailable(version: release.version, checkedAt: checkedAt)
                defaults.set("available", forKey: Self.lastUpdateOutcomeKey)
                defaults.set(currentVersion, forKey: Self.lastCheckedAppVersionKey)
                statusMessage = "发现新版本 \(release.version)"
            } else {
                availableRelease = nil
                updateCheckResult = .upToDate(checkedAt)
                defaults.set("upToDate", forKey: Self.lastUpdateOutcomeKey)
                defaults.set(currentVersion, forKey: Self.lastCheckedAppVersionKey)
                if !silent { statusMessage = "RelayDock \(currentVersion) 已是最新版本" }
            }
        } catch {
            let message = error.localizedDescription
            updateCheckResult = .failed(message: message, checkedAt: Date())
            if !silent { statusMessage = "更新检查失败：\(message)" }
        }
    }

    func installAvailableUpdate() {
        guard let release = availableRelease,
              !isDownloadingUpdate,
              !updateInstallerWasOpened else { return }
        isDownloadingUpdate = true
        updateInstallerWasOpened = false
        statusMessage = "正在下载并验证 RelayDock \(release.version)…"
        Task {
            defer { isDownloadingUpdate = false }
            do {
                let fileURL = try await GitHubUpdater.downloadDMG(from: release)
                statusMessage = "下载完成，正在验证安装内容…"
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try UpdateInstaller.prepare(dmgURL: fileURL, expectedVersion: release.version)
                }.value
                guard NSWorkspace.shared.open(prepared.launcherURL) else {
                    UpdateInstaller.discard(prepared)
                    throw UpdateInstallError.launcherFailed
                }
                updateInstallerWasOpened = true
                statusMessage = "安装器已打开；确认后会验证版本并重启 RelayDock"
            } catch {
                statusMessage = "更新安装准备失败：\(error.localizedDescription)"
            }
        }
    }

    func resetUpdateInstallerHandoff() {
        guard updateInstallerWasOpened else { return }
        updateInstallerWasOpened = false
        statusMessage = "可以重新启动更新安装器"
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

    func openCursor() {
        do {
            try CursorLauncher.openNormally()
            statusMessage = "Cursor 已打开；第三方端点仍需通过 Cursor 支持的方式配置"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func clearDiagnostics() {
        events.removeAll()
        statusMessage = "诊断记录已清除"
    }

    func removeLocalData() {
        do {
            cancelEndpointOperations()
            stopProbe()
            defaults.removeObject(forKey: Self.profilesKey)
            defaults.removeObject(forKey: Self.legacyProfileKey)
            defaults.removeObject(forKey: Self.selectedProfileKey)
            defaults.removeObject(forKey: Self.lastUpdateCheckKey)
            defaults.removeObject(forKey: Self.lastUpdateOutcomeKey)
            defaults.removeObject(forKey: Self.lastCheckedAppVersionKey)
            try KeychainStore.removeAll()
            try OpenCodeIntegration.removeGeneratedFiles()
            let profile = GatewayProfile()
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

    private func applyDiscoveredModels(_ modelIDs: [String]) {
        let existing = Dictionary(uniqueKeysWithValues: draftProfile.models.map { ($0.modelID, $0) })
        draftProfile.models = modelIDs.map { modelID in
            if let saved = existing[modelID] { return saved }
            return GatewayModel(modelID: modelID, displayName: modelID)
        }
        if let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) {
            profiles[index] = draftProfile
            _ = persistProfiles()
        }
        modelProbeStates.removeAll()
    }

    private func cancelEndpointOperations() {
        let hadOperation = endpointOperationToken != nil
        endpointOperationToken = nil
        catalogTask?.cancel()
        catalogTask = nil
        modelTestTask?.cancel()
        modelTestTask = nil
        if hadOperation { isBusy = false }
    }

    private static func shouldRetryLegacyTokenParameter(data: Data, statusCode: Int) -> Bool {
        guard statusCode == 400 || statusCode == 422,
              let message = String(data: data, encoding: .utf8)?.lowercased(),
              message.contains("max_completion_tokens") else { return false }
        return message.contains("unsupported")
            || message.contains("unknown")
            || message.contains("unrecognized")
            || message.contains("not permitted")
    }
}

enum EndpointError: LocalizedError {
    case invalidResponse
    var errorDescription: String? { "端点响应无效" }
}
