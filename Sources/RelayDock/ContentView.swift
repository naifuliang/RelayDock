import SwiftUI

struct ContentView: View {
    private enum PendingNavigation {
        case add
        case select(UUID)
        case preset(EndpointPreset)
    }

    @ObservedObject var model: AppModel
    @State private var showCleanupConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var showUnsavedChanges = false
    @State private var showModelTestConfirmation = false
    @State private var pendingNavigation: PendingNavigation?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    pageHeader
                    quickConnectCard
                    endpointConfigurationCard
                    launcherCard
                    updateCard
                    diagnosticsCard
                    footer
                }
                .padding(28)
                .frame(maxWidth: 1120)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .preferredColorScheme(.light)
        .alert(L10n.t("Delete this endpoint?", zh: "删除这个端点？"), isPresented: $showDeleteConfirmation) {
            Button(L10n.t("Cancel", zh: "取消"), role: .cancel) {}
            Button(L10n.t("Delete", zh: "删除"), role: .destructive) { model.deleteSelectedProfile() }
        } message: {
            Text(L10n.t(
                "This deletes the endpoint and its Keychain API key. Other endpoints are not affected.",
                zh: "将删除该端点及其钥匙串 API Key，不会影响其他端点。"
            ))
        }
        .alert(L10n.t("Test all models?", zh: "测试全部模型？"), isPresented: $showModelTestConfirmation) {
            Button(L10n.t("Cancel", zh: "取消"), role: .cancel) {}
            Button(L10n.t("Start tests", zh: "开始测试")) { model.testAllModels() }
        } message: {
            Text(L10n.t(
                "RelayDock sends one minimal request to every enabled model and may incur a very small amount of API usage. Models the provider reports as missing, unavailable, or unauthorized are removed automatically; auth, rate-limit, network, and server failures are kept so they are not deleted by mistake.",
                zh: "RelayDock 会向每个已启用模型发送一次最小请求，可能产生极少量 API 用量。服务商明确返回模型不存在、不可用或无权限时，会自动从清单移除；鉴权、限流、网络和服务端故障会保留，避免误删。"
            ))
        }
        .alert(L10n.t("This endpoint has unsaved changes", zh: "当前端点有未保存的更改"), isPresented: $showUnsavedChanges) {
            Button(L10n.t("Cancel", zh: "取消"), role: .cancel) { pendingNavigation = nil }
            Button(L10n.t("Discard changes", zh: "放弃更改"), role: .destructive) { performPendingNavigation(saveFirst: false) }
            Button(L10n.t("Save and continue", zh: "保存并继续")) { performPendingNavigation(saveFirst: true) }
        } message: {
            Text(L10n.t(
                "Save the current edits or discard them before switching or adding an endpoint.",
                zh: "切换或添加端点前，请选择保存当前编辑或放弃更改。"
            ))
        }
        .alert(L10n.t("Clear RelayDock local data?", zh: "清除 RelayDock 本地数据？"), isPresented: $showCleanupConfirmation) {
            Button(L10n.t("Cancel", zh: "取消"), role: .cancel) {}
            Button(L10n.t("Clear", zh: "清除"), role: .destructive) { model.removeLocalData() }
        } message: {
            Text(L10n.t(
                "This deletes every endpoint, diagnostic record, generated OpenCode configuration, and API key RelayDock saved in Keychain.",
                zh: "将删除所有端点、诊断记录、生成的 OpenCode 配置和 RelayDock 保存到钥匙串中的 API Key。"
            ))
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 11) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("RelayDock").font(.headline)
                    Text(L10n.t("Endpoint launcher", zh: "端点启动器")).font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Label(L10n.t("Setup", zh: "配置"), systemImage: "slider.horizontal.3")
                    .fontWeight(.medium)
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                Label(
                    L10n.t("{0} endpoints", zh: "{0} 个 Endpoint", "\(model.profiles.count)"),
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 11).padding(.vertical, 8)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Button { model.configureOpenCode(launch: true) } label: {
                    sidebarLauncherLabel(L10n.t("Open OpenCode", zh: "打开 OpenCode"), systemImage: "terminal")
                }
                .disabled(!model.openCodeInstalled)
                Button { model.openCursor() } label: {
                    sidebarLauncherLabel(L10n.t("Open Cursor", zh: "打开 Cursor"), systemImage: "cursorarrow")
                }
                .disabled(!model.cursorInstalled)
                Link(destination: RelayDockLinks.codexSub2APISetupGuide) {
                    sidebarLauncherLabel(L10n.t("Help & Setup Guide", zh: "帮助与配置说明"), systemImage: "questionmark.circle")
                }
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Language", zh: "语言"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
                languagePicker
            }

            Text("v\(model.currentVersion)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 218)
        .background(Color.white)
    }

    private func sidebarLauncherLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .frame(width: 20, alignment: .center)
            Text(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.t("Setup", zh: "配置")).font(.largeTitle.bold())
            Text(L10n.t("One place to manage multiple endpoints, keys, and models.", zh: "一个配置管理多个 Endpoint、密钥与模型。"))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var endpointConfigurationCard: some View {
        cleanCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Endpoints").font(.title3.bold())
                        Text(L10n.t("Each endpoint has its own protocol, URL, key, and model list.", zh: "每个 Endpoint 使用独立协议、地址、Key 和模型列表。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.t("Add Endpoint", zh: "添加 Endpoint"), systemImage: "plus", action: attemptAddProfile)
                        .buttonStyle(.bordered)
                }

                if model.credentialMigrationAvailable {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "key.horizontal.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.t("Repair Keychain access once", zh: "需要一次性修复 Keychain 访问")).fontWeight(.semibold)
                            Text(L10n.t(
                                "After this update, ordinary actions such as Sync Models will not read old credentials. After you start the repair, macOS may ask for authorization once; the original data is not deleted until the new vault verifies successfully.",
                                zh: "更新后的 App 不会在同步模型等普通操作中读取旧凭据。点击修复后，macOS 可能授权一次；新仓库验证成功前不会删除原数据。"
                            ))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.t("Repair Keychain once", zh: "一次性修复 Keychain"), action: model.migrateSavedCredentials)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.orange.opacity(0.22), lineWidth: 1)
                    )
                }

                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 7) {
                        ForEach(model.profiles) { profile in
                            endpointRow(profile)
                        }
                    }
                    .frame(width: 210)

                    Divider()
                    endpointEditor
                }
            }
        }
    }

    private var quickConnectCard: some View {
        cleanCard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("Quick connect for coding services", zh: "Coding 服务快速接入")).font(.title3.bold())
                    Text(L10n.t(
                        "Add an official compatible configuration in one click. RelayDock does not sell plans, sign in to provider accounts, or reuse a web subscription.",
                        zh: "一键添加官方兼容配置；RelayDock 不代购套餐、不登录服务商账户，也不会复用网页订阅。"
                    ))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    ForEach(EndpointPreset.allCases) { preset in
                        quickConnectTile(preset)
                    }
                }
            }
        }
    }

    private func quickConnectTile(_ preset: EndpointPreset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: presetIcon(preset)).font(.title3)
                Text(preset.title).fontWeight(.semibold)
                Spacer()
            }
            Text(preset.detail)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.t("The key is written to macOS Keychain only when you save", zh: "Key 仅在保存时写入 macOS Keychain"))
                .font(.caption2).foregroundStyle(.tertiary)
            Button(L10n.t("Add configuration", zh: "添加配置"), systemImage: "plus") { attemptAddPreset(preset) }
                .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.black.opacity(0.085), lineWidth: 1)
        )
    }

    private func endpointRow(_ profile: GatewayProfile) -> some View {
        Button { attemptSelectProfile(profile.id) } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(profile.isEnabled ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName).fontWeight(.medium).lineLimit(1)
                    Text("\(profile.provider.title) · \(profile.models.count) models")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.bold()).foregroundStyle(.tertiary)
            }
            .padding(11)
            .background(
                profile.id == model.selectedProfileID ? Color.black.opacity(0.06) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var endpointEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.draftProfile.displayName).font(.headline)
                Spacer()
                Toggle(L10n.t("Enabled", zh: "启用"), isOn: $model.draftProfile.isEnabled)
                    .toggleStyle(.switch).controlSize(.small)
            }
            formRow(L10n.t("Name", zh: "名称")) {
                TextField(L10n.t("For example, OpenAI Production", zh: "例如 OpenAI Production"), text: $model.draftProfile.displayName)
            }
            formRow(L10n.t("Protocol", zh: "协议")) {
                Picker("", selection: $model.draftProfile.provider) {
                    ForEach(ProviderKind.allCases) { Text($0.title).tag($0) }
                }.labelsHidden()
            }
            formRow("Base URL") {
                TextField(endpointPlaceholder, text: $model.draftProfile.baseURL)
            }
            if model.draftProfile.provider == .azureOpenAI {
                formRow("API Version") {
                    TextField("v1", text: $model.draftProfile.azureAPIVersion)
                }
                Toggle(L10n.t("Use Azure’s retired deployment URLs", zh: "使用 Azure 旧版 deployment URL"), isOn: $model.draftProfile.azureDeploymentBasedURLs)
                if model.draftProfile.azureDeploymentBasedURLs {
                    Text(L10n.t(
                        "Azure retired the legacy deployment-list API; add deployment IDs manually, then verify them in one click.",
                        zh: "Azure 已停用旧版 deployment 列表接口；请手动添加 deployment ID，随后可一键验证。"
                    ))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            formRow("API Key") {
                HStack(spacing: 8) {
                    SecureField(
                        model.credentialMayExist && !model.credentialLoaded
                            ? L10n.t("Saved; load it or type a new key", zh: "已保存；点击加载或直接输入新 Key")
                            : L10n.t("Saved securely in macOS Keychain", zh: "安全保存到 macOS Keychain"),
                        text: $model.apiKey
                    )
                    if model.credentialMayExist && !model.credentialLoaded {
                        Button(L10n.t("Load", zh: "加载"), action: model.loadSelectedCredential)
                            .buttonStyle(.bordered)
                    }
                }
            }
            if model.credentialMayExist && !model.credentialLoaded {
                Text(L10n.t(
                    "Saved keys are not read automatically at launch or when switching endpoints, so an update does not suddenly prompt for Keychain access.",
                    zh: "为避免更新后突然弹出 Keychain 验证，已保存的 Key 不会在启动或切换 Endpoint 时自动读取。"
                ))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let preset = EndpointPreset.matching(model.draftProfile) {
                Label(preset.credentialHelp, systemImage: "key.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 2)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Models").font(.headline)
                    Text(L10n.t("Synced automatically after a connection test; you can also add models by hand.", zh: "测试连接后会自动同步；也可以手动添加。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.t("Add", zh: "添加"), systemImage: "plus") { model.addModel() }
                    .buttonStyle(.borderless)
            }

            if model.draftProfile.models.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.slash").foregroundStyle(.secondary)
                    Text(L10n.t("No models yet", zh: "还没有模型")).fontWeight(.medium)
                    Text(L10n.t("Use Sync Models to fetch them automatically.", zh: "点击“测试并获取模型”自动同步。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 20)
                .background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 0) {
                    ForEach($model.draftProfile.models) { $route in
                        modelRow($route)
                        if route.id != model.draftProfile.models.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 10)
                .background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 9) {
                Button(L10n.t("Save", zh: "保存")) { model.saveSelectedProfile() }
                    .buttonStyle(.borderedProminent)
                Button(L10n.t("Sync Models", zh: "同步模型")) { model.testEndpoint() }
                    .disabled(model.isBusy || usesLegacyAzureDeployments)
                    .help(L10n.t("Test the endpoint and fetch models automatically", zh: "测试 Endpoint 并自动获取模型"))
                Button(L10n.t("Verify All", zh: "一键验证全部")) { showModelTestConfirmation = true }
                    .disabled(model.isBusy || model.draftProfile.models.isEmpty)
                Spacer()
                Menu {
                    Button(L10n.t("Delete Endpoint…", zh: "删除 Endpoint…"), role: .destructive) { showDeleteConfirmation = true }
                        .disabled(model.profiles.count <= 1)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity)
    }

    private func modelRow(_ route: Binding<GatewayModel>) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: route.isEnabled).labelsHidden().toggleStyle(.checkbox)
            TextField(L10n.t("Model ID", zh: "模型 ID"), text: Binding(
                get: { route.wrappedValue.modelID },
                set: { value in
                    if route.wrappedValue.modelID != value {
                        route.wrappedValue.modelID = value
                        route.wrappedValue.isVerified = false
                    }
                }
            ))
            TextField(L10n.t("Display name (optional)", zh: "显示名称（可选）"), text: route.displayName)
            modelStateView(
                model.modelProbeStates[route.wrappedValue.id],
                verified: route.wrappedValue.isVerified
            )
            Button(role: .destructive) { model.removeModel(route.wrappedValue.id) } label: {
                Image(systemName: "minus.circle")
            }.buttonStyle(.plain)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func modelStateView(_ state: ModelProbeState?, verified: Bool) -> some View {
        switch state {
        case .testing:
            ProgressView().controlSize(.small).help(L10n.t("Testing", zh: "正在测试"))
        case .available:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help(L10n.t("Available", zh: "可用"))
        case let .failed(reason):
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help(reason)
        case nil:
            if verified {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help(L10n.t("Verified available", zh: "已验证可用"))
            } else {
                Image(systemName: "circle").foregroundStyle(.tertiary).help(L10n.t("Not tested yet", zh: "尚未测试"))
            }
        }
    }

    private var launcherCard: some View {
        cleanCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Launchers").font(.title3.bold())
                HStack(spacing: 12) {
                    launcherTile(
                        title: "OpenCode",
                        detail: L10n.t(
                            "Write an isolated configuration and launch with every enabled endpoint.",
                            zh: "写入独立配置并带上全部已启用 Endpoint 启动。"
                        ),
                        installed: model.openCodeInstalled,
                        icon: "terminal",
                        actionTitle: L10n.t("Configure and open", zh: "配置并打开"),
                        action: { model.configureOpenCode(launch: true) }
                    )
                    launcherTile(
                        title: "Cursor",
                        detail: L10n.t(
                            "Write BYOK settings in one transaction, start the local domain-scoped Bridge, then open Cursor.",
                            zh: "事务写入 BYOK 配置，启动本地域限定 Bridge 后打开。"
                        ),
                        installed: model.cursorInstalled,
                        icon: "cursorarrow",
                        actionTitle: L10n.t("Configure and open", zh: "配置并打开"),
                        action: model.configureAndLaunchCursor
                    )
                }
                Text(L10n.t(
                    "Only models that passed per-model verification are imported. Any failure in the Cursor database schema, key migration, or Bridge verification rolls back automatically.",
                    zh: "只导入已经逐模型验证为可用的模型。Cursor 数据库结构、Key 迁移或 Bridge 验证任一步失败都会自动回滚。"
                ))
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                cursorBYOKAssistant
            }
        }
    }

    private var cursorBYOKAssistant: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.t("Cursor one-click Sub2API", zh: "Cursor 一键接入 Sub2API"), systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer()
                if model.bridgeRunning {
                    Label("Bridge · 127.0.0.1:\(model.bridgePort ?? 0)", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }
            Text(L10n.t(
                "OpenAI Compatible: write the OpenAI key, Override Base URL, and verified models. Anthropic: write only the Claude key; api.anthropic.com is forwarded by the local Bridge using a domain-scoped certificate to the selected endpoint.",
                zh: "OpenAI Compatible：写入 OpenAI Key、Override Base URL 和已验证模型。Anthropic：只写 Claude Key；api.anthropic.com 由本地 Bridge 使用限定域名证书转发到所选 Endpoint。"
            ))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(
                L10n.t(
                    "Egress inherits HTTP_PROXY / HTTPS_PROXY / ALL_PROXY if they were already set at launch; otherwise it follows the macOS default proxy and exceptions. Enabling the Bridge does not force a direct connection.",
                    zh: "出口会继承启动时已有的 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY；否则遵循 macOS 默认代理和例外规则。不会因启用 Bridge 改成直接出网。"
                ),
                systemImage: "arrow.triangle.branch"
            )
            .font(.caption).foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("OpenAI Compatible").font(.caption.weight(.semibold))
                    Picker("OpenAI Compatible", selection: $model.cursorOpenAIProfileID) {
                        Text(L10n.t("Don’t import", zh: "不导入")).tag(Optional<UUID>.none)
                        ForEach(model.cursorOpenAIProfiles) { profile in
                            Text(L10n.t("{0} · {1} models", zh: "{0} · {1} 模型", profile.displayName, "\(model.cursorImportableModelCount(for: profile))"))
                                .tag(Optional(profile.id))
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Anthropic").font(.caption.weight(.semibold))
                    Picker("Anthropic", selection: $model.cursorAnthropicProfileID) {
                        Text(L10n.t("Don’t import", zh: "不导入")).tag(Optional<UUID>.none)
                        ForEach(model.cursorAnthropicProfiles) { profile in
                            Text(L10n.t("{0} · {1} models", zh: "{0} · {1} 模型", profile.displayName, "\(model.cursorImportableModelCount(for: profile))"))
                                .tag(Optional(profile.id))
                        }
                    }
                    .labelsHidden()
                }
            }

            if model.cursorAnthropicProfileID != nil {
                Label(
                    L10n.t(
                        "The first use asks macOS to authorize a certificate. The SAN contains only api.anthropic.com and CA:FALSE; other hostnames are not decrypted, and you can remove it at any time.",
                        zh: "首次使用会请求一次 macOS 证书授权。证书 SAN 仅含 api.anthropic.com、CA:FALSE；不会解密其他域名，可随时一键移除。"
                    ),
                    systemImage: "lock.shield"
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    model.configureAndLaunchCursor()
                } label: {
                    Label(L10n.t("Configure and open Cursor", zh: "一键配置并打开 Cursor"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || !model.cursorInstalled)

                Button(L10n.t("Install Bridge certificate only", zh: "仅安装 Bridge 证书")) { model.installAnthropicBridgeCertificate() }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                Button(L10n.t("Uninstall Bridge", zh: "卸载 Bridge")) { model.removeAnthropicBridge() }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                Button(L10n.t("Restore last Cursor settings", zh: "恢复上次 Cursor 配置")) { model.restoreLatestCursorConfiguration() }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy || !model.cursorInstalled)

                Spacer()
                Text(model.bridgeCertificateTrusted
                     ? L10n.t("Certificate verified", zh: "证书已验证")
                     : L10n.t("Certificate not verified", zh: "证书未验证"))
                    .font(.caption)
                    .foregroundStyle(model.bridgeCertificateTrusted ? .green : .secondary)
            }
        }
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.black.opacity(0.085), lineWidth: 1)
        )
    }

    private func launcherTile(
        title: String, detail: String, installed: Bool, icon: String,
        actionTitle: String, action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).fontWeight(.semibold)
                    Text(installed ? L10n.t("Installed", zh: "已安装") : L10n.t("Not found", zh: "未找到"))
                        .font(.caption2).foregroundStyle(installed ? .green : .orange)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(actionTitle, action: action).buttonStyle(.borderedProminent).disabled(!installed)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
    }

    private var updateCard: some View {
        cleanCard {
            HStack(spacing: 14) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Updates · v\(model.currentVersion)").font(.headline)
                    if let release = model.availableRelease {
                        Text(L10n.t(
                            "RelayDock {0} is available; SHA-256, version, and the app signature are verified before install.",
                            zh: "RelayDock {0} 可用；安装前会校验 SHA-256、版本和 App 签名。",
                            release.version
                        ))
                            .font(.caption).foregroundStyle(.secondary)
                        updateResultRow
                    } else {
                        updateResultRow
                    }
                }
                Spacer()
                Toggle(L10n.t("Auto-check", zh: "自动检查"), isOn: $model.automaticUpdateChecks).toggleStyle(.switch).controlSize(.small)
                if model.availableRelease != nil {
                    if model.updateInstallerWasOpened {
                        VStack(alignment: .trailing, spacing: 4) {
                            Button(L10n.t("Installer opened", zh: "安装器已打开")) {}.disabled(true)
                            Button(L10n.t("Install cancelled? Try again", zh: "安装已取消？重新尝试")) { model.resetUpdateInstallerHandoff() }
                                .buttonStyle(.link).font(.caption)
                        }
                    } else {
                        Button(model.isDownloadingUpdate
                               ? L10n.t("Preparing install…", zh: "准备安装…")
                               : L10n.t("Download and install…", zh: "下载并安装…")) { model.installAvailableUpdate() }
                            .disabled(model.isDownloadingUpdate)
                    }
                } else {
                    Button(model.isCheckingForUpdates
                           ? L10n.t("Checking…", zh: "检查中…")
                           : L10n.t("Check for Updates", zh: "检查更新")) {
                        Task { await model.checkForUpdates() }
                    }.disabled(model.isCheckingForUpdates)
                }
            }
        }
    }

    @ViewBuilder
    private var updateResultRow: some View {
        switch model.updateCheckResult {
        case .idle:
            Label(L10n.t("Updates have not been checked yet", zh: "尚未检查更新"), systemImage: "minus.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.t("Checking GitHub Releases…", zh: "正在检查 GitHub Release…"))
            }
            .font(.caption).foregroundStyle(.secondary)
        case let .upToDate(date):
            Label(L10n.t("Up to date · {0}", zh: "已是最新版本 · {0}", date.formatted(date: .omitted, time: .shortened)), systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case let .updateAvailable(version, checkedAt):
            Label(L10n.t("Found v{0} · {1}", zh: "发现 v{0} · {1}", version, checkedAt.formatted(date: .omitted, time: .shortened)), systemImage: "arrow.down.circle.fill")
                .font(.caption).foregroundStyle(.blue)
        case let .failed(message, checkedAt):
            Label(L10n.t("Check failed · {0} · {1}", zh: "检查失败 · {0} · {1}", checkedAt.formatted(date: .omitted, time: .shortened), message), systemImage: "exclamationmark.circle.fill")
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    private var diagnosticsCard: some View {
        cleanCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.t("Recent connections", zh: "最近连接")).font(.headline)
                    Spacer()
                    Button(L10n.t("Clear", zh: "清除")) { model.clearDiagnostics() }.disabled(model.events.isEmpty)
                }
                if model.events.isEmpty {
                    Text(L10n.t(
                        "No connections yet. After you launch Cursor through the RelayDock proxy, destinations appear here.",
                        zh: "暂无连接。通过 RelayDock 代理启动 Cursor 后，连接目标会显示在这里。"
                    ))
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
                } else {
                    ForEach(model.events.prefix(30)) { event in
                        HStack {
                            Image(systemName: event.isAnthropic ? "checkmark.seal.fill" : "arrow.left.arrow.right")
                                .foregroundStyle(event.isAnthropic ? .green : .secondary)
                            Text(event.host).font(.system(.body, design: .monospaced))
                            Text(":\(event.port)").foregroundStyle(.secondary)
                            Spacer()
                            Text(event.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                            Text(event.timestamp, style: .time).font(.caption).foregroundStyle(.tertiary)
                        }
                        Divider()
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(model.statusMessage).foregroundStyle(.secondary)
            Spacer()
            Button(L10n.t("Clear local data…", zh: "清除本地数据…"), role: .destructive) { showCleanupConfirmation = true }
        }.font(.callout)
    }

    private func cleanCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(20)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.black.opacity(0.075), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.035), radius: 10, y: 3)
    }

    private func formRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 108, alignment: .leading)
            content().frame(maxWidth: .infinity)
        }
    }

    private var languagePicker: some View {
        Picker(L10n.t("Language", zh: "语言"), selection: $model.language) {
            ForEach(AppLanguage.allCases) { language in
                Text(language.nativeName).tag(language)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(L10n.t("Language", zh: "语言"))
    }

    private var endpointPlaceholder: String {
        switch model.draftProfile.provider {
        case .azureOpenAI: return "https://resource.openai.azure.com/openai"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openAICompatible, .openAIResponses: return "https://api.example.com/v1"
        }
    }

    private var usesLegacyAzureDeployments: Bool {
        model.draftProfile.provider == .azureOpenAI && model.draftProfile.azureDeploymentBasedURLs
    }

    private func presetIcon(_ preset: EndpointPreset) -> String {
        switch preset {
        case .openAI: return "sparkles"
        case .kimi: return "moon.stars"
        case .arkCodingPlan: return "flame"
        }
    }

    private func attemptSelectProfile(_ id: UUID) {
        guard id != model.selectedProfileID else { return }
        if model.hasUnsavedProfileChanges {
            pendingNavigation = .select(id)
            showUnsavedChanges = true
        } else { model.selectProfile(id) }
    }

    private func attemptAddProfile() {
        if model.hasUnsavedProfileChanges {
            pendingNavigation = .add
            showUnsavedChanges = true
        } else { model.addProfile() }
    }

    private func attemptAddPreset(_ preset: EndpointPreset) {
        if model.hasUnsavedProfileChanges {
            pendingNavigation = .preset(preset)
            showUnsavedChanges = true
        } else { model.addProfile(from: preset) }
    }

    private func performPendingNavigation(saveFirst: Bool) {
        guard let pendingNavigation else { return }
        if saveFirst, !model.saveSelectedProfile() {
            self.pendingNavigation = nil
            return
        }
        if !saveFirst {
            model.discardSelectedProfileChanges()
        }
        switch pendingNavigation {
        case .add: model.addProfile()
        case let .select(id): model.selectProfile(id)
        case let .preset(preset): model.addProfile(from: preset)
        }
        self.pendingNavigation = nil
    }

}

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L10n.t("Open RelayDock", zh: "打开 RelayDock")) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Text(L10n.t("Endpoints: {0} enabled", zh: "Endpoint：{0} 个已启用", "\(model.profiles.filter(\.isEnabled).count)"))
        Button(L10n.t("Open OpenCode", zh: "打开 OpenCode")) { model.configureOpenCode(launch: true) }.disabled(!model.openCodeInstalled)
        Button(L10n.t("Configure and open Cursor", zh: "配置并打开 Cursor")) { model.configureAndLaunchCursor() }.disabled(!model.cursorInstalled)
        Divider()
        languageMenu
        Divider()
        Button(model.isCheckingForUpdates
               ? L10n.t("Checking for updates…", zh: "正在检查更新…")
               : L10n.t("Check for Updates", zh: "检查更新")) {
            Task { await model.checkForUpdates() }
        }
        .disabled(model.isCheckingForUpdates)
        Link(L10n.t("Help & Setup Guide", zh: "帮助与配置说明"), destination: RelayDockLinks.codexSub2APISetupGuide)
        Divider()
        Button(L10n.t("Quit RelayDock", zh: "退出 RelayDock")) {
            model.stopProbe()
            model.stopAnthropicBridge()
            NSApp.terminate(nil)
        }
    }

    private var languageMenu: some View {
        Menu(L10n.t("Language", zh: "语言")) {
            ForEach(AppLanguage.allCases) { language in
                Button(language.nativeName) {
                    model.language = language
                }
            }
        }
    }
}
