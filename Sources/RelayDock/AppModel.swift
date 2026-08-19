import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var profiles: [GatewayProfile]
    @Published var selectedProfileID: UUID
    @Published var draftProfile: GatewayProfile
    @Published var apiKey: String
    @Published private(set) var credentialLoaded = false
    @Published private(set) var credentialMayExist = false
    @Published private(set) var credentialMigrationAvailable = false
    @Published private(set) var proxyRunning = false
    @Published private(set) var proxyPort: UInt16?
    @Published private(set) var events: [ProxyEvent] = []
    @Published private(set) var statusMessage = L10n.t("Ready", zh: "准备就绪")
    @Published var language: AppLanguage = .english {
        willSet { L10n.language = newValue }
        didSet {
            defaults.set(language.rawValue, forKey: Self.languageKey)
            refreshStatusMessage()
        }
    }
    @Published private(set) var isBusy = false
    @Published private(set) var availableRelease: GitHubRelease?
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var isDownloadingUpdate = false
    @Published private(set) var updateInstallerWasOpened = false
    @Published private(set) var updateCheckResult: UpdateCheckResult = .idle
    @Published private(set) var modelProbeStates: [UUID: ModelProbeState] = [:]
    @Published var cursorOpenAIProfileID: UUID? {
        didSet { persistOptionalUUID(cursorOpenAIProfileID, key: Self.cursorOpenAIProfileKey) }
    }
    @Published var cursorAnthropicProfileID: UUID? {
        didSet { persistOptionalUUID(cursorAnthropicProfileID, key: Self.cursorAnthropicProfileKey) }
    }
    @Published private(set) var bridgeRunning = false
    @Published private(set) var bridgePort: UInt16?
    @Published private(set) var bridgeCertificateTrusted = false
    @Published var automaticUpdateChecks: Bool {
        didSet { defaults.set(automaticUpdateChecks, forKey: Self.automaticUpdatesKey) }
    }

    private let defaults: UserDefaults
    private let credentialStore: CredentialStoreClient
    private var proxy: ProbeProxy?
    private var anthropicBridge: AnthropicBridgeProxy?
    private var anthropicNodeBridge: AnthropicBridgeProxy?
    private var activeProxyToken: UUID?
    private var catalogTask: Task<Void, Never>?
    private var modelTestTask: Task<Void, Never>?
    private var clipboardClearTask: Task<Void, Never>?
    private var endpointOperationToken: UUID?
    private var savedAPIKey: String
    private var legacyProfileCredentialID: UUID?
    private static let profilesKey = "gatewayProfiles.v2"
    private static let legacyProfileKey = "endpointProfile"
    private static let selectedProfileKey = "selectedGatewayProfileID"
    private static let automaticUpdatesKey = "automaticUpdateChecks"
    private static let lastUpdateCheckKey = "lastUpdateCheck"
    private static let lastUpdateOutcomeKey = "lastUpdateOutcome"
    private static let lastCheckedAppVersionKey = "lastCheckedAppVersion"
    private static let cursorOpenAIProfileKey = "cursorOpenAIProfileID"
    private static let cursorAnthropicProfileKey = "cursorAnthropicProfileID"
    private static let credentialMigrationCompleteKey = "credentialVaultMigrationComplete.v1"
    private static let credentialRepairPendingKey = "credentialVaultRepairPending.v3"
    private static let legacyCredentialProfileKey = "legacyCredentialProfileID.v1"
    static let languageKey = "appLanguage"

    init(
        defaults: UserDefaults = .standard,
        scheduleAutomaticUpdateCheck: Bool = true,
        credentialStore: CredentialStoreClient = .live
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
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
            credentialLoaded = false
            credentialMayExist = false
            credentialMigrationAvailable = false
            automaticUpdateChecks = false
            cursorOpenAIProfileID = first.id
            cursorAnthropicProfileID = second.id
            language = .english
            L10n.language = .english
            setStatus { L10n.t("Ready", zh: "准备就绪") }
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
        apiKey = ""
        savedAPIKey = ""
        credentialLoaded = false
        let persistedLegacyID = defaults.string(forKey: Self.legacyCredentialProfileKey)
            .flatMap(UUID.init(uuidString:))
        legacyProfileCredentialID = migratedLegacy
            ? initialID
            : initialProfiles.contains(where: { $0.id == persistedLegacyID }) ? persistedLegacyID : nil
        if migratedLegacy {
            defaults.set(initialID.uuidString, forKey: Self.legacyCredentialProfileKey)
        }
        credentialMayExist = credentialStore.presence(
            initialID,
            legacyProfileCredentialID == initialID
        ).mayExist
        credentialMigrationAvailable = defaults.bool(forKey: Self.credentialRepairPendingKey)
            || credentialStore.migrationNeeded(initialProfiles.map(\.id), legacyProfileCredentialID != nil)
        automaticUpdateChecks = defaults.object(forKey: Self.automaticUpdatesKey) as? Bool ?? true
        language = AppLanguage.resolved(stored: defaults.string(forKey: Self.languageKey))
        L10n.language = language
        setStatus { L10n.t("Ready", zh: "准备就绪") }
        let savedCursorOpenAIID = defaults.string(forKey: Self.cursorOpenAIProfileKey).flatMap(UUID.init(uuidString:))
        let savedCursorAnthropicID = defaults.string(forKey: Self.cursorAnthropicProfileKey).flatMap(UUID.init(uuidString:))
        cursorOpenAIProfileID = Self.validCursorOpenAIProfiles(initialProfiles).contains(where: { $0.id == savedCursorOpenAIID })
            ? savedCursorOpenAIID
            : Self.validCursorOpenAIProfiles(initialProfiles).first?.id
        cursorAnthropicProfileID = Self.validCursorAnthropicProfiles(initialProfiles).contains(where: { $0.id == savedCursorAnthropicID })
            ? savedCursorAnthropicID
            : Self.validCursorAnthropicProfiles(initialProfiles).first?.id

        if migratedLegacy, !persistProfiles() {
            setStatus {
                L10n.t(
                    "Legacy endpoint settings were not persisted; the API key has not been read",
                    zh: "旧端点配置暂未持久化；API Key 尚未读取"
                )
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
    var cursorOpenAIProfiles: [GatewayProfile] { Self.validCursorOpenAIProfiles(profiles) }
    var cursorAnthropicProfiles: [GatewayProfile] { Self.validCursorAnthropicProfiles(profiles) }
    func cursorImportableModelCount(for profile: GatewayProfile) -> Int {
        CursorModelRouting.modelIDs(for: profile).count
    }
    var cursorBYOKProfile: GatewayProfile? {
        guard draftProfile.provider == .openAICompatible,
              EndpointValidator.normalizedURL(from: draftProfile.baseURL) != nil,
              draftProfile.models.contains(where: {
                  $0.isEnabled && !$0.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            return nil
        }
        return draftProfile
    }
    var hasUnsavedProfileChanges: Bool {
        let credentialChanged = credentialLoaded
            ? apiKey != savedAPIKey
            : !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return draftProfile != profiles.first(where: { $0.id == selectedProfileID }) || credentialChanged
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
        resetCredentialField(for: id)
        defaults.set(id.uuidString, forKey: Self.selectedProfileKey)
        setStatus { [unowned self] in
            self.credentialMayExist
                ? L10n.t("Switched to {0}; the key has not been read", zh: "已切换到 {0}；Key 尚未读取", profile.displayName)
                : L10n.t("Switched to {0}", zh: "已切换到 {0}", profile.displayName)
        }
    }

    func discardSelectedProfileChanges() {
        guard let profile = profiles.first(where: { $0.id == selectedProfileID }) else { return }
        cancelEndpointOperations()
        draftProfile = profile
        if credentialLoaded {
            apiKey = savedAPIKey
        } else {
            apiKey = ""
        }
        setStatus { L10n.t("Discarded unsaved changes", zh: "已放弃未保存的更改") }
    }

    func loadSelectedCredential() {
        guard !credentialMigrationAvailable else {
            setStatus {
                L10n.t(
                    "Repair Keychain once first; RelayDock will not read old credentials during ordinary actions",
                    zh: "请先点击“一次性修复 Keychain”；RelayDock 不会在普通操作中读取旧凭据"
                )
            }
            return
        }
        do {
            let key = try credentialStore.loadForUserAction(
                selectedProfileID,
                legacyProfileCredentialID == selectedProfileID
            )
            apiKey = key
            savedAPIKey = key
            credentialLoaded = true
            credentialMayExist = !key.isEmpty
            refreshCredentialMigrationState()
            markCredentialMigrationCompleteIfNoLegacyItemsRemain()
            setStatus {
                key.isEmpty
                    ? L10n.t("This endpoint has no saved API key", zh: "当前端点没有已保存的 API Key")
                    : L10n.t("API key loaded", zh: "API Key 已加载")
            }
        } catch {
            setStatus { L10n.t("Could not read the API key: {0}", zh: "无法读取 API Key：{0}", error.localizedDescription) }
        }
    }

    func migrateSavedCredentials() {
        defaults.set(true, forKey: Self.credentialRepairPendingKey)
        do {
            let report = try credentialStore.migrate(profiles.map(\.id), legacyProfileCredentialID)
            if report.unresolvedProfileCount == 0 {
                legacyProfileCredentialID = nil
                defaults.removeObject(forKey: Self.legacyCredentialProfileKey)
                defaults.set(true, forKey: Self.credentialMigrationCompleteKey)
                defaults.removeObject(forKey: Self.credentialRepairPendingKey)
            }
            refreshCredentialMigrationState()
            resetCredentialField(for: selectedProfileID)
            if report.unresolvedProfileCount == 0 {
                setStatus {
                    L10n.t(
                        "Keychain repair complete; saved keys were written to the new vault owned by this signature",
                        zh: "Keychain 修复完成；已保存的 Key 已写入当前签名拥有的新凭据仓库"
                    )
                }
            } else {
                setStatus {
                    L10n.t(
                        "Some credentials were migrated; {0} old keys were not authorized and were left unchanged",
                        zh: "已迁移部分凭据；{0} 个旧 Key 未获授权并保持原状",
                        "\(report.unresolvedProfileCount)"
                    )
                }
            }
        } catch {
            setStatus {
                L10n.t(
                    "Legacy credential migration failed; original data was not deleted: {0}",
                    zh: "旧凭据迁移失败，原数据未删除：{0}",
                    error.localizedDescription
                )
            }
        }
    }

    func addProfile() {
        cancelEndpointOperations()
        let profile = GatewayProfile(displayName: "Gateway \(profiles.count + 1)")
        profiles.append(profile)
        persistProfiles()
        selectProfile(profile.id)
        setStatus { L10n.t("Added a new endpoint", zh: "已添加新端点") }
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
        setStatus {
            L10n.t(
                "Added {0}; enter the provider API key, then sync models",
                zh: "已添加 {0}；请填写服务商 API Key 后同步模型",
                preset.profileName
            )
        }
    }

    func deleteSelectedProfile() {
        cancelEndpointOperations()
        guard !credentialMigrationAvailable else {
            setStatus {
                L10n.t(
                    "Repair Keychain once first, then delete an endpoint that still has saved credentials",
                    zh: "请先点击“一次性修复 Keychain”，再删除保存过凭据的 Endpoint"
                )
            }
            return
        }
        guard profiles.count > 1,
              let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) else {
            setStatus { L10n.t("Keep at least one endpoint", zh: "至少需要保留一个端点") }
            return
        }
        let removed = profiles[index]
        do {
            try credentialStore.remove(removed.id)
        } catch {
            setStatus {
                L10n.t(
                    "Could not delete the endpoint Keychain credential: {0}",
                    zh: "无法删除端点 Keychain 凭据：{0}",
                    error.localizedDescription
                )
            }
            return
        }
        profiles.remove(at: index)
        if cursorOpenAIProfileID == removed.id { cursorOpenAIProfileID = nil }
        if cursorAnthropicProfileID == removed.id { cursorAnthropicProfileID = nil }
        persistProfiles()
        let next = profiles[min(index, profiles.count - 1)]
        selectProfile(next.id)
        setStatus { L10n.t("Deleted endpoint “{0}”", zh: "端点“{0}”已删除", removed.displayName) }
    }

    @discardableResult
    func saveSelectedProfile() -> Bool {
        do {
            guard let url = EndpointValidator.normalizedURL(from: draftProfile.baseURL) else {
                setStatus {
                    L10n.t(
                        "Invalid endpoint URL; remote addresses require HTTPS",
                        zh: "端点地址无效；远程地址需要 HTTPS"
                    )
                }
                return false
            }
            let name = draftProfile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                setStatus { L10n.t("Enter an endpoint name", zh: "请填写端点名称") }
                return false
            }
            let modelIDs = draftProfile.models
                .map { $0.modelID.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard Set(modelIDs).count == modelIDs.count else {
                setStatus {
                    L10n.t(
                        "The same endpoint cannot contain duplicate model IDs",
                        zh: "同一个端点中不能有重复的模型 ID"
                    )
                }
                return false
            }

            draftProfile.displayName = name
            draftProfile.baseURL = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) else { return false }
            let previous = profiles[index]
            // A key typed into an endpoint whose stored value was never loaded
            // still replaces that credential, so previous verification results
            // no longer describe the route that will actually be used.
            let credentialChanged = credentialLoaded
                ? savedAPIKey != apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                : !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let endpointChanged = previous.provider != draftProfile.provider
                || previous.baseURL != draftProfile.baseURL
                || credentialChanged
            if endpointChanged {
                for modelIndex in draftProfile.models.indices {
                    draftProfile.models[modelIndex].isVerified = false
                }
            } else {
                let previousIDs = Dictionary(uniqueKeysWithValues: previous.models.map { ($0.id, $0.modelID) })
                for modelIndex in draftProfile.models.indices
                where previousIDs[draftProfile.models[modelIndex].id] != draftProfile.models[modelIndex].modelID {
                    draftProfile.models[modelIndex].isVerified = false
                }
            }
            let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let shouldWriteCredential = credentialLoaded || !normalizedKey.isEmpty
            if shouldWriteCredential {
                guard !credentialMigrationAvailable else {
                    throw KeychainMigrationError.migrationRequired
                }
                try credentialStore.save(normalizedKey, selectedProfileID)
            }
            profiles[index] = draftProfile
            guard persistProfiles() else {
                throw KeychainMigrationError.profilePersistenceFailed
            }
            if shouldWriteCredential {
                savedAPIKey = normalizedKey
                apiKey = normalizedKey
                credentialLoaded = true
                credentialMayExist = !normalizedKey.isEmpty
                refreshCredentialMigrationState()
            }
            setStatus { L10n.t("Endpoint “{0}” was saved securely", zh: "端点“{0}”已安全保存", name) }
            return true
        } catch {
            setStatus { error.localizedDescription }
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
            setStatus {
                L10n.t(
                    "Add deployment IDs manually for Azure’s retired deployment URL mode",
                    zh: "Azure 旧版 deployment 模式请手动添加 deployment ID"
                )
            }
            return
        }
        let key: String
        do {
            key = try credentialForUserAction(profileID: selectedProfileID)
        } catch {
            setStatus { L10n.t("Could not read the API key: {0}", zh: "无法读取 API Key：{0}", error.localizedDescription) }
            return
        }
        guard !key.isEmpty else {
            setStatus {
                L10n.t(
                    "Enter or load the API key for this endpoint",
                    zh: "请填写或加载当前端点的 API Key"
                )
            }
            return
        }
        let profile = draftProfile
        cancelEndpointOperations()
        let operationToken = UUID()
        endpointOperationToken = operationToken
        isBusy = true
        setStatus { L10n.t("Testing the model API…", zh: "正在测试模型接口…") }

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
                    let session = try RelayDockNetwork.session(for: request.url!)
                    defer { session.invalidateAndCancel() }
                    let (data, response) = try await session.data(for: request)
                    try Task.checkCancellation()
                    guard endpointOperationToken == operationToken else { return }
                    guard let http = response as? HTTPURLResponse else { throw EndpointError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else {
                        setStatus { L10n.t("Endpoint returned HTTP {0}", zh: "端点返回 HTTP {0}", "\(http.statusCode)") }
                        return
                    }
                    discoveredModelIDs.append(contentsOf: ModelCatalogParser.modelIDs(from: data))
                    afterID = profile.provider == .anthropic ? ModelCatalogParser.nextCursor(from: data) : nil
                    pageCount += 1
                } while afterID != nil && pageCount < 20
                var seenModelIDs = Set<String>()
                discoveredModelIDs = discoveredModelIDs.filter { seenModelIDs.insert($0).inserted }
                if discoveredModelIDs.isEmpty {
                    setStatus {
                        L10n.t(
                            "Connected, but no text-generation models were recognized",
                            zh: "连接成功，但没有识别到文本生成模型"
                        )
                    }
                } else {
                    guard selectedProfileID == profile.id else { return }
                    applyDiscoveredModels(discoveredModelIDs)
                    setStatus {
                        L10n.t(
                            "Connected; fetched {0} text-generation models",
                            zh: "连接成功，已获取 {0} 个文本生成模型",
                            "\(discoveredModelIDs.count)"
                        )
                    }
                }
            } catch {
                guard endpointOperationToken == operationToken else { return }
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    setStatus { L10n.t("Model sync was cancelled", zh: "模型同步已取消") }
                } else {
                    setStatus { L10n.t("Connection failed: {0}", zh: "连接失败：{0}", error.localizedDescription) }
                }
            }
        }
    }

    func testAllModels() {
        guard saveSelectedProfile() else { return }
        let routes = draftProfile.models.filter { $0.isEnabled && !$0.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !routes.isEmpty else {
            setStatus {
                L10n.t(
                    "Fetch or add at least one enabled model first",
                    zh: "请先获取或添加至少一个已启用模型"
                )
            }
            return
        }
        let profile = draftProfile
        let key: String
        do {
            key = try credentialForUserAction(profileID: selectedProfileID)
        } catch {
            setStatus { L10n.t("Could not read the API key: {0}", zh: "无法读取 API Key：{0}", error.localizedDescription) }
            return
        }
        guard !key.isEmpty else {
            setStatus {
                L10n.t(
                    "Enter or load the API key for this endpoint",
                    zh: "请填写或加载当前端点的 API Key"
                )
            }
            return
        }
        cancelEndpointOperations()
        let operationToken = UUID()
        endpointOperationToken = operationToken
        modelProbeStates = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, .testing) })
        isBusy = true
        setStatus { L10n.t("Testing {0} models one by one…", zh: "正在逐个测试 {0} 个模型…", "\(routes.count)") }

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
            var unavailableRouteIDs = Set<UUID>()
            for route in routes {
                guard !Task.isCancelled else {
                    if endpointOperationToken == operationToken {
                        setStatus { L10n.t("Model verification was cancelled", zh: "模型验证已取消") }
                    }
                    return
                }
                do {
                    let modelID = route.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
                    let request = try ModelAPIRequestFactory.probe(
                        profile: profile,
                        modelID: modelID,
                        apiKey: key
                    )
                    let session = try RelayDockNetwork.session(for: request.url!)
                    defer { session.invalidateAndCancel() }
                    var (responseData, response) = try await session.data(for: request)
                    if let http = response as? HTTPURLResponse,
                       Self.shouldRetryLegacyTokenParameter(data: responseData, statusCode: http.statusCode),
                       let fallback = try ModelAPIRequestFactory.legacyTokenFallback(
                           profile: profile, modelID: modelID, apiKey: key
                       ) {
                        (responseData, response) = try await session.data(for: fallback)
                    }
                    try Task.checkCancellation()
                    guard endpointOperationToken == operationToken else { return }
                    guard let http = response as? HTTPURLResponse else { throw EndpointError.invalidResponse }
                    if (200..<300).contains(http.statusCode) {
                        modelProbeStates[route.id] = .available
                        if let index = draftProfile.models.firstIndex(where: { $0.id == route.id }) {
                            draftProfile.models[index].isVerified = true
                        }
                        availableCount += 1
                    } else {
                        modelProbeStates[route.id] = .failed("HTTP \(http.statusCode)")
                        if let index = draftProfile.models.firstIndex(where: { $0.id == route.id }) {
                            draftProfile.models[index].isVerified = false
                        }
                        if ModelVerificationPolicy.isDefinitivelyUnavailable(
                            statusCode: http.statusCode,
                            responseData: responseData
                        ) {
                            unavailableRouteIDs.insert(route.id)
                        }
                    }
                } catch {
                    guard endpointOperationToken == operationToken else { return }
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                        setStatus { L10n.t("Model verification was cancelled", zh: "模型验证已取消") }
                        return
                    }
                    modelProbeStates[route.id] = .failed(error.localizedDescription)
                    if let index = draftProfile.models.firstIndex(where: { $0.id == route.id }) {
                        draftProfile.models[index].isVerified = false
                    }
                }
            }
            guard endpointOperationToken == operationToken,
                  selectedProfileID == profile.id else { return }
            if !unavailableRouteIDs.isEmpty {
                draftProfile.models.removeAll { unavailableRouteIDs.contains($0.id) }
                unavailableRouteIDs.forEach { self.modelProbeStates.removeValue(forKey: $0) }
            }
            if let index = profiles.firstIndex(where: { $0.id == self.selectedProfileID }) {
                profiles[index] = draftProfile
                _ = persistProfiles()
            }
            if profile.provider == .openAICompatible,
               cursorOpenAIProfileID == nil,
               Self.validCursorOpenAIProfiles(profiles).contains(where: { $0.id == profile.id }) {
                cursorOpenAIProfileID = profile.id
            }
            if profile.provider == .anthropic,
               cursorAnthropicProfileID == nil,
               Self.validCursorAnthropicProfiles(profiles).contains(where: { $0.id == profile.id }) {
                cursorAnthropicProfileID = profile.id
            }
            let retainedFailureCount = routes.count - availableCount - unavailableRouteIDs.count
            setStatus {
                var message = L10n.t(
                    "Model tests finished: {0} available, {1} definitively unavailable models were removed",
                    zh: "模型测试完成：{0} 个可用，自动排除 {1} 个明确不可用",
                    "\(availableCount)",
                    "\(unavailableRouteIDs.count)"
                )
                if retainedFailureCount > 0 {
                    message += L10n.t(
                        "; {0} transient or auth failures were kept",
                        zh: "；{0} 个瞬时/鉴权失败已保留",
                        "\(retainedFailureCount)"
                    )
                }
                return message
            }
        }
    }

    func configureOpenCode(
        launch: Bool,
        directory: URL = OpenCodeIntegration.configurationDirectory,
        revealGeneratedConfiguration: Bool = true
    ) {
        if launch {
            do {
                try OpenCodeIntegration.validateLaunchAvailability()
            } catch {
                setStatus { error.localizedDescription }
                return
            }
        }
        guard saveSelectedProfile() else { return }
        do {
            // Only endpoints that are actually exported are unlocked. A disabled
            // or unverified endpoint must not make this action read a credential.
            let exportedProfiles = OpenCodeIntegration.exportableProfiles(profiles)
            let keys = try Dictionary(uniqueKeysWithValues: exportedProfiles.map {
                ($0.id, try credentialForUserAction(profileID: $0.id))
            })
            let configURL = try OpenCodeIntegration.generateConfiguration(
                profiles: profiles,
                apiKeys: keys,
                directory: directory
            )
            if launch {
                try OpenCodeIntegration.launch(configURL: configURL, directory: directory)
                setStatus {
                    L10n.t(
                        "OpenCode launched with {0} verified RelayDock endpoints",
                        zh: "OpenCode 已使用 {0} 个已验证 RelayDock 端点启动",
                        "\(exportedProfiles.count)"
                    )
                }
            } else {
                if revealGeneratedConfiguration {
                    NSWorkspace.shared.activateFileViewerSelecting([configURL])
                }
                setStatus { L10n.t("OpenCode configuration generated", zh: "OpenCode 配置已生成") }
            }
        } catch {
            setStatus { error.localizedDescription }
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
        if !silent { setStatus { L10n.t("Checking GitHub for updates…", zh: "正在检查 GitHub 更新…") } }
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
                setStatus { L10n.t("New version {0} is available", zh: "发现新版本 {0}", release.version) }
            } else {
                availableRelease = nil
                updateCheckResult = .upToDate(checkedAt)
                defaults.set("upToDate", forKey: Self.lastUpdateOutcomeKey)
                defaults.set(currentVersion, forKey: Self.lastCheckedAppVersionKey)
                if !silent {
                    let version = currentVersion
                    setStatus {
                        L10n.t(
                            "RelayDock {0} is up to date",
                            zh: "RelayDock {0} 已是最新版本",
                            version
                        )
                    }
                }
            }
        } catch {
            let message = error.localizedDescription
            updateCheckResult = .failed(message: message, checkedAt: Date())
            if !silent {
                setStatus { L10n.t("Update check failed: {0}", zh: "更新检查失败：{0}", message) }
            }
        }
    }

    func installAvailableUpdate() {
        guard let release = availableRelease,
              !isDownloadingUpdate,
              !updateInstallerWasOpened else { return }
        isDownloadingUpdate = true
        updateInstallerWasOpened = false
        setStatus {
            L10n.t(
                "Downloading and verifying RelayDock {0}…",
                zh: "正在下载并验证 RelayDock {0}…",
                release.version
            )
        }
        Task {
            defer { isDownloadingUpdate = false }
            do {
                let fileURL = try await GitHubUpdater.downloadDMG(from: release)
                setStatus {
                    L10n.t(
                        "Download complete; verifying the installer…",
                        zh: "下载完成，正在验证安装内容…"
                    )
                }
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try UpdateInstaller.prepare(dmgURL: fileURL, expectedVersion: release.version)
                }.value
                guard NSWorkspace.shared.open(prepared.launcherURL) else {
                    UpdateInstaller.discard(prepared)
                    throw UpdateInstallError.launcherFailed
                }
                updateInstallerWasOpened = true
                setStatus {
                    L10n.t(
                        "Installer opened; RelayDock will verify the version and restart after you confirm",
                        zh: "安装器已打开；确认后会验证版本并重启 RelayDock"
                    )
                }
            } catch {
                setStatus {
                    L10n.t(
                        "Could not prepare the update installer: {0}",
                        zh: "更新安装准备失败：{0}",
                        error.localizedDescription
                    )
                }
            }
        }
    }

    func resetUpdateInstallerHandoff() {
        guard updateInstallerWasOpened else { return }
        updateInstallerWasOpened = false
        setStatus { L10n.t("You can restart the update installer", zh: "可以重新启动更新安装器") }
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
                    self?.setStatus {
                        running
                            ? L10n.t("Probe proxy is listening on 127.0.0.1:{0}", zh: "探测代理正在监听 127.0.0.1:{0}", "\(port ?? 0)")
                            : L10n.t("Probe proxy stopped", zh: "探测代理已停止")
                    }
                }
            }
        )
        self.proxy = proxy
        do {
            try proxy.start()
            setStatus { L10n.t("Starting the probe proxy…", zh: "正在启动探测代理…") }
        } catch {
            setStatus { L10n.t("Proxy failed to start: {0}", zh: "代理启动失败：{0}", error.localizedDescription) }
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
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let proxyPort = try await ensureProbeReady()
                if restart { try await CursorLauncher.terminate() }
                try CursorLauncher.launch(proxyPort: proxyPort)
                setStatus {
                    L10n.t(
                        "Cursor launched through the probe proxy; the proxy does not change Cursor’s models or endpoints",
                        zh: "Cursor 已通过探测代理启动；代理不会自动修改 Cursor 的模型或 Endpoint"
                    )
                }
            } catch {
                setStatus { error.localizedDescription }
            }
        }
    }

    func configureAndLaunchCursor() {
        guard !isBusy else { return }
        guard saveSelectedProfile() else { return }
        let openAIProfile = cursorOpenAIProfiles.first { $0.id == cursorOpenAIProfileID }
        let anthropicProfile = cursorAnthropicProfiles.first { $0.id == cursorAnthropicProfileID }
        guard openAIProfile != nil || anthropicProfile != nil else {
            setStatus {
                L10n.t(
                    "Verify models first, then select at least one Cursor endpoint",
                    zh: "请先测试模型，然后选择至少一个 Cursor Endpoint"
                )
            }
            return
        }

        let openAIKey: String?
        let anthropicKey: String?
        do {
            openAIKey = try openAIProfile.map { try credentialForUserAction(profileID: $0.id) }
            anthropicKey = try anthropicProfile.map { try credentialForUserAction(profileID: $0.id) }
        } catch {
            setStatus {
                L10n.t(
                    "Could not read the Cursor endpoint API key: {0}",
                    zh: "无法读取 Cursor Endpoint API Key：{0}",
                    error.localizedDescription
                )
            }
            return
        }
        if openAIProfile != nil, openAIKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            setStatus {
                L10n.t(
                    "The selected OpenAI Compatible endpoint has no usable API key",
                    zh: "所选 OpenAI Compatible Endpoint 没有可用 API Key"
                )
            }
            return
        }
        if anthropicProfile != nil, anthropicKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            setStatus {
                L10n.t(
                    "The selected Anthropic endpoint has no usable API key",
                    zh: "所选 Anthropic Endpoint 没有可用 API Key"
                )
            }
            return
        }

        let modelIDs = [openAIProfile, anthropicProfile]
            .compactMap { $0 }
            .flatMap(CursorModelRouting.modelIDs)
        let request = CursorImportRequest(
            openAIBaseURL: openAIProfile?.baseURL,
            openAIKey: openAIKey,
            anthropicKey: anthropicKey,
            modelIDs: modelIDs
        )
        isBusy = true
        setStatus {
            anthropicProfile == nil
                ? L10n.t("Configuring Cursor securely…", zh: "正在安全配置 Cursor…")
                : L10n.t(
                    "Preparing the api.anthropic.com domain-scoped certificate and Cursor settings…",
                    zh: "正在准备 api.anthropic.com 域限定证书与 Cursor 配置…"
                )
        }

        Task { [weak self] in
            guard let self else { return }
            var receipt: CursorImportReceipt?
            var installedBridgeTrustThisAttempt = false
            do {
                try await CursorLauncher.terminate()
                stopProbe()
                stopAnthropicBridge()

                var material: BridgeCertificateMaterial?
                var nodeMaterial: BridgeCertificateMaterial?
                if anthropicProfile != nil {
                    material = try await Task.detached(priority: .userInitiated) {
                        try BridgeCertificateManager.ensureMaterial()
                    }.value
                    nodeMaterial = try await Task.detached(priority: .userInitiated) {
                        try CursorNodeBridgeCertificateManager.ensureMaterial()
                    }.value
                    if let material {
                        let wasTrusted = try await Task.detached(priority: .utility) {
                            try BridgeCertificateManager.isTrusted(material)
                        }.value
                        installedBridgeTrustThisAttempt = !wasTrusted
                        if !wasTrusted {
                            _ = try await Task.detached(priority: .userInitiated) {
                                try BridgeCertificateManager.installTrust()
                            }.value
                        }
                    }
                    bridgeCertificateTrusted = true
                }

                receipt = try await Task.detached(priority: .userInitiated) {
                    try CursorConfiguration.apply(request)
                }.value

                if let anthropicProfile, let anthropicKey, let material, let nodeMaterial,
                   let baseURL = EndpointValidator.normalizedURL(from: anthropicProfile.baseURL) {
                    let route = try AnthropicBridgeRoute(baseURL: baseURL, apiKey: anthropicKey)
                    let upstreamProxyResolver = UpstreamProxyResolver()
                    // Resolve before writing/launching any more state. Unsupported
                    // local proxy modes fail closed instead of silently bypassing
                    // the user's existing egress path.
                    _ = try upstreamProxyResolver.route(to: baseURL)
                    let eventHandler: AnthropicBridgeProxy.EventHandler = { [weak self] event in
                        Task { @MainActor in
                            self?.events.insert(event, at: 0)
                            if self?.events.count ?? 0 > 200 { self?.events.removeLast() }
                        }
                    }
                    let bridge = AnthropicBridgeProxy(
                        route: route,
                        material: material,
                        upstreamProxyResolver: upstreamProxyResolver,
                        onEvent: eventHandler,
                        onState: { [weak self] running, port in
                            Task { @MainActor in
                                self?.bridgeRunning = running
                                self?.bridgePort = port
                            }
                        }
                    )
                    let nodeBridge = AnthropicBridgeProxy(
                        route: route,
                        material: nodeMaterial,
                        upstreamProxyResolver: upstreamProxyResolver,
                        onEvent: eventHandler,
                        onState: { _, _ in }
                    )
                    anthropicBridge = bridge
                    anthropicNodeBridge = nodeBridge
                    let port = try bridge.start()
                    let nodePort = try nodeBridge.start()
                    try CursorLauncher.launch(
                        proxyPort: port,
                        nodeProxyPort: nodePort,
                        nodeTrustAnchorURL: nodeMaterial.nodeTrustAnchorURL
                    )
                } else {
                    try CursorLauncher.openNormally()
                }

                guard let receipt else { throw CursorConfigurationError.invalidBackup }
                var finalized = false
                for _ in 0..<40 {
                    try await Task.sleep(for: .milliseconds(250))
                    do {
                        try await Task.detached(priority: .utility) {
                            try CursorConfiguration.finalize(receipt)
                        }.value
                        finalized = true
                        break
                    } catch CursorConfigurationError.keyMigrationIncomplete {
                        continue
                    }
                }
                guard finalized else { throw CursorConfigurationError.keyMigrationIncomplete }
                setStatus { [unowned self] in
                    anthropicProfile == nil
                        ? L10n.t(
                            "Cursor finished OpenAI Compatible setup and launched",
                            zh: "Cursor 已完成 OpenAI Compatible 配置并启动"
                        )
                        : L10n.t(
                            "Cursor finished OpenAI + Anthropic Sub2API setup; the Bridge is running on 127.0.0.1:{0}",
                            zh: "Cursor 已完成 OpenAI + Anthropic Sub2API 配置；Bridge 正在 127.0.0.1:{0} 运行",
                            "\(self.bridgePort ?? 0)"
                        )
                }
            } catch {
                let configurationError = error
                stopAnthropicBridge()
                if let receipt {
                    do {
                        try await CursorLauncher.terminate()
                        try await Task.detached(priority: .userInitiated) {
                            try CursorConfiguration.rollback(receipt)
                        }.value
                        setStatus {
                            L10n.t(
                                "Cursor one-click setup failed; original settings were restored: {0}",
                                zh: "Cursor 一键配置失败，已恢复原配置：{0}",
                                configurationError.localizedDescription
                            )
                        }
                    } catch {
                        setStatus {
                            L10n.t(
                                "Cursor one-click setup failed and automatic rollback did not finish: {0}; rollback error: {1}. Keep Cursor quit and retry with the rollback snapshot RelayDock kept.",
                                zh: "Cursor 一键配置失败，且自动回滚未完成：{0}；回滚错误：{1}。请保持 Cursor 关闭并使用 RelayDock 中保留的回滚快照重试。",
                                configurationError.localizedDescription,
                                error.localizedDescription
                            )
                        }
                    }
                } else {
                    setStatus {
                        L10n.t(
                            "Cursor one-click setup failed before writing Cursor: {0}",
                            zh: "Cursor 一键配置失败，尚未写入 Cursor：{0}",
                            configurationError.localizedDescription
                        )
                    }
                }
                if installedBridgeTrustThisAttempt {
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try BridgeCertificateManager.removeTrust()
                        }.value
                        bridgeCertificateTrusted = false
                    } catch {
                        bridgeCertificateTrusted = true
                        let revokeError = error
                        let prefix = statusRenderer
                        setStatus {
                            prefix() + L10n.t(
                                "; the Bridge certificate trust added this time could not be revoked: {0}",
                                zh: "；本次新增的 Bridge 证书信任未能自动撤销：{0}",
                                revokeError.localizedDescription
                            )
                        }
                    }
                }
            }
            isBusy = false
        }
    }

    func installAnthropicBridgeCertificate() {
        guard !isBusy else { return }
        isBusy = true
        setStatus {
            L10n.t(
                "Generating and authorizing a certificate scoped only to api.anthropic.com…",
                zh: "正在生成并授权仅限 api.anthropic.com 的证书…"
            )
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let material = try await Task.detached(priority: .userInitiated) {
                    try BridgeCertificateManager.installTrust()
                }.value
                bridgeCertificateTrusted = try await Task.detached(priority: .utility) {
                    try BridgeCertificateManager.isTrusted(material)
                }.value
                setStatus { [unowned self] in
                    self.bridgeCertificateTrusted
                        ? L10n.t(
                            "Anthropic Bridge certificate installed and domain trust verified",
                            zh: "Anthropic Bridge 证书已安装并通过域名信任验证"
                        )
                        : L10n.t("Certificate did not pass trust verification", zh: "证书未通过信任验证")
                }
            } catch {
                bridgeCertificateTrusted = false
                setStatus {
                    L10n.t(
                        "Certificate installation failed: {0}",
                        zh: "证书安装失败：{0}",
                        error.localizedDescription
                    )
                }
            }
            isBusy = false
        }
    }

    func restoreLatestCursorConfiguration() {
        guard !isBusy else { return }
        isBusy = true
        setStatus {
            L10n.t(
                "Restoring the latest Cursor configuration snapshot…",
                zh: "正在恢复最近一次 Cursor 配置快照…"
            )
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await CursorLauncher.terminate()
                stopAnthropicBridge()
                try await Task.detached(priority: .userInitiated) {
                    try CursorConfiguration.rollbackLatest()
                }.value
                setStatus {
                    L10n.t(
                        "The latest Cursor configuration snapshot was restored",
                        zh: "最近一次 Cursor 配置快照已恢复"
                    )
                }
            } catch {
                setStatus {
                    L10n.t(
                        "Could not restore the Cursor configuration: {0}",
                        zh: "Cursor 配置恢复失败：{0}",
                        error.localizedDescription
                    )
                }
            }
            isBusy = false
        }
    }

    func removeAnthropicBridge() {
        guard !isBusy else { return }
        stopAnthropicBridge()
        isBusy = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try BridgeCertificateManager.removeAll()
                }.value
                bridgeCertificateTrusted = false
                setStatus {
                    L10n.t(
                        "Anthropic Bridge certificate, private key, and trust settings were removed",
                        zh: "Anthropic Bridge 证书、私钥和信任设置已移除"
                    )
                }
            } catch {
                setStatus { L10n.t("Bridge uninstall failed: {0}", zh: "Bridge 卸载失败：{0}", error.localizedDescription) }
            }
            isBusy = false
        }
    }

    func stopAnthropicBridge() {
        let activeBridge = anthropicBridge
        let activeNodeBridge = anthropicNodeBridge
        anthropicBridge = nil
        anthropicNodeBridge = nil
        bridgeRunning = false
        bridgePort = nil
        activeBridge?.stop()
        activeNodeBridge?.stop()
    }

    func copyCursorBaseURL() {
        guard let profile = cursorBYOKProfile else {
            setStatus {
                L10n.t(
                    "Select an OpenAI Compatible endpoint that has available models",
                    zh: "请选择一个含可用模型的 OpenAI Compatible Endpoint"
                )
            }
            return
        }
        copyToPasteboard(profile.baseURL)
        setStatus { L10n.t("Copied the Cursor Override OpenAI Base URL", zh: "已复制 Cursor Override OpenAI Base URL") }
    }

    func copyCursorAPIKey() {
        guard cursorBYOKProfile != nil else {
            setStatus {
                L10n.t(
                    "Select an OpenAI Compatible endpoint that has available models",
                    zh: "请选择一个含可用模型的 OpenAI Compatible Endpoint"
                )
            }
            return
        }
        let key: String
        do {
            key = try credentialForUserAction(profileID: selectedProfileID)
        } catch {
            setStatus { L10n.t("Could not read the API key: {0}", zh: "无法读取 API Key：{0}", error.localizedDescription) }
            return
        }
        guard !key.isEmpty else {
            setStatus { L10n.t("This endpoint has no API key to copy", zh: "当前 Endpoint 没有可复制的 API Key") }
            return
        }
        clipboardClearTask?.cancel()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(key, forType: .string)
        let changeCount = pasteboard.changeCount
        clipboardClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, pasteboard.changeCount == changeCount else { return }
            pasteboard.clearContents()
            self?.setStatus {
                L10n.t(
                    "The Cursor API key was cleared from the clipboard",
                    zh: "Cursor API Key 已从剪贴板自动清除"
                )
            }
        }
        setStatus {
            L10n.t(
                "API key copied; it will be cleared from the clipboard in 60 seconds",
                zh: "API Key 已复制，60 秒后自动从剪贴板清除"
            )
        }
    }

    func copyCursorModelIDs() {
        guard let profile = cursorBYOKProfile else {
            setStatus {
                L10n.t(
                    "Select an OpenAI Compatible endpoint that has available models",
                    zh: "请选择一个含可用模型的 OpenAI Compatible Endpoint"
                )
            }
            return
        }
        let modelIDs = profile.models
            .filter(\.isEnabled)
            .map(\.modelID)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        copyToPasteboard(modelIDs.joined(separator: "\n"))
        setStatus { L10n.t("Copied {0} model IDs", zh: "已复制 {0} 个模型 ID", "\(modelIDs.count)") }
    }

    func openCursor() {
        do {
            try CursorLauncher.openNormally()
            setStatus {
                L10n.t(
                    "Cursor opened; third-party endpoints still need to be configured the way Cursor supports",
                    zh: "Cursor 已打开；第三方端点仍需通过 Cursor 支持的方式配置"
                )
            }
        } catch {
            setStatus { error.localizedDescription }
        }
    }

    private func ensureProbeReady() async throws -> UInt16 {
        if proxyRunning, let proxyPort { return proxyPort }
        startProbe()
        for _ in 0..<50 {
            if proxyRunning, let proxyPort { return proxyPort }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LauncherError.proxyStartTimedOut
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    func clearDiagnostics() {
        events.removeAll()
        setStatus { L10n.t("Diagnostics cleared", zh: "诊断记录已清除") }
    }

    func removeLocalData() {
        cancelEndpointOperations()
        stopProbe()
        stopAnthropicBridge()
        var failures: [String] = []
        func attempt(_ label: String, _ operation: () throws -> Void) {
            do {
                try operation()
            } catch {
                failures.append(L10n.t("{0}: {1}", zh: "{0}：{1}", label, error.localizedDescription))
            }
        }
        attempt(L10n.t("Bridge certificate and trust", zh: "Bridge 证书与信任"), { try BridgeCertificateManager.removeAll() })
        attempt(L10n.t("Keychain credentials", zh: "钥匙串凭据"), { try credentialStore.removeAll() })
        attempt(L10n.t("OpenCode configuration", zh: "OpenCode 配置"), { try OpenCodeIntegration.removeGeneratedFiles() })
        attempt(L10n.t("Cursor rollback files", zh: "Cursor 回滚文件"), { try CursorConfiguration.removeBackups() })
        guard failures.isEmpty else {
            setStatus {
                L10n.t(
                    "Cleanup did not finish completely; RelayDock kept the endpoint settings so you can retry. ",
                    zh: "清理未全部完成；RelayDock 已保留端点配置以便重试。"
                ) + failures.joined(separator: L10n.t("; ", zh: "；"))
            }
            return
        }

        defaults.removeObject(forKey: Self.profilesKey)
        defaults.removeObject(forKey: Self.legacyProfileKey)
        defaults.removeObject(forKey: Self.selectedProfileKey)
        defaults.removeObject(forKey: Self.lastUpdateCheckKey)
        defaults.removeObject(forKey: Self.lastUpdateOutcomeKey)
        defaults.removeObject(forKey: Self.lastCheckedAppVersionKey)
        defaults.removeObject(forKey: Self.credentialMigrationCompleteKey)
        defaults.removeObject(forKey: Self.credentialRepairPendingKey)
        defaults.removeObject(forKey: Self.legacyCredentialProfileKey)
        let profile = GatewayProfile()
        profiles = [profile]
        selectedProfileID = profile.id
        draftProfile = profile
        apiKey = ""
        savedAPIKey = ""
        credentialLoaded = false
        credentialMayExist = false
        credentialMigrationAvailable = false
        legacyProfileCredentialID = nil
        events.removeAll()
        if persistProfiles() {
            setStatus {
                L10n.t(
                    "RelayDock endpoints, OpenCode configuration, and Keychain credentials were cleared",
                    zh: "RelayDock 端点、OpenCode 配置和钥匙串凭据已清除"
                )
            }
        } else {
            setStatus {
                L10n.t(
                    "Sensitive data was cleared, but a new blank endpoint could not be written; restart RelayDock.",
                    zh: "敏感数据已清除，但无法写入新的空白端点配置；请重新启动 RelayDock。"
                )
            }
        }
    }

    private var statusRenderer: () -> String = { L10n.t("Ready", zh: "准备就绪") }

    private func setStatus(_ renderer: @escaping () -> String) {
        statusRenderer = renderer
        statusMessage = renderer()
    }

    private func refreshStatusMessage() {
        statusMessage = statusRenderer()
    }

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

    private func persistOptionalUUID(_ id: UUID?, key: String) {
        if let id {
            defaults.set(id.uuidString, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func resetCredentialField(for profileID: UUID) {
        apiKey = ""
        savedAPIKey = ""
        credentialLoaded = false
        credentialMayExist = credentialStore.presence(
            profileID,
            legacyProfileCredentialID == profileID
        ).mayExist
    }

    private func refreshCredentialMigrationState() {
        credentialMigrationAvailable = defaults.bool(forKey: Self.credentialRepairPendingKey)
            || credentialStore.migrationNeeded(profiles.map(\.id), legacyProfileCredentialID != nil)
    }

    private func credentialForUserAction(profileID: UUID) throws -> String {
        guard !credentialMigrationAvailable else {
            throw KeychainMigrationError.migrationRequired
        }
        if profileID == selectedProfileID, credentialLoaded {
            return apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let key = try credentialStore.loadForUserAction(
            profileID,
            legacyProfileCredentialID == profileID
        )
        if profileID == selectedProfileID {
            apiKey = key
            savedAPIKey = key
            credentialLoaded = true
            credentialMayExist = !key.isEmpty
        }
        refreshCredentialMigrationState()
        markCredentialMigrationCompleteIfNoLegacyItemsRemain()
        return key
    }

    private func markCredentialMigrationCompleteIfNoLegacyItemsRemain() {
        guard !credentialMigrationAvailable else { return }
        legacyProfileCredentialID = nil
        defaults.removeObject(forKey: Self.legacyCredentialProfileKey)
        defaults.set(true, forKey: Self.credentialMigrationCompleteKey)
    }

    private static func validCursorOpenAIProfiles(_ profiles: [GatewayProfile]) -> [GatewayProfile] {
        profiles.filter { profile in
            profile.isEnabled
                && profile.provider == .openAICompatible
                && EndpointValidator.normalizedURL(from: profile.baseURL) != nil
                && !CursorModelRouting.modelIDs(for: profile).isEmpty
        }
    }

    private static func validCursorAnthropicProfiles(_ profiles: [GatewayProfile]) -> [GatewayProfile] {
        profiles.filter { profile in
            profile.isEnabled
                && profile.provider == .anthropic
                && EndpointValidator.normalizedURL(from: profile.baseURL) != nil
                && !CursorModelRouting.modelIDs(for: profile).isEmpty
        }
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
    var errorDescription: String? { L10n.t("The endpoint response is invalid", zh: "端点响应无效") }
}
