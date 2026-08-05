import SwiftUI

struct ContentView: View {
    private enum PendingNavigation {
        case add
        case select(UUID)
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
                    endpointConfigurationCard
                    launcherCard
                    updateCard
                    probeCard
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
        .alert("删除这个端点？", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { model.deleteSelectedProfile() }
        } message: {
            Text("将删除该端点及其钥匙串 API Key，不会影响其他端点。")
        }
        .alert("测试全部模型？", isPresented: $showModelTestConfirmation) {
            Button("取消", role: .cancel) {}
            Button("开始测试") { model.testAllModels() }
        } message: {
            Text("RelayDock 会向每个已启用模型发送一次最小请求，可能产生极少量 API 用量。")
        }
        .alert("当前端点有未保存的更改", isPresented: $showUnsavedChanges) {
            Button("取消", role: .cancel) { pendingNavigation = nil }
            Button("放弃更改", role: .destructive) { performPendingNavigation(saveFirst: false) }
            Button("保存并继续") { performPendingNavigation(saveFirst: true) }
        } message: {
            Text("切换或添加端点前，请选择保存当前编辑或放弃更改。")
        }
        .alert("清除 RelayDock 本地数据？", isPresented: $showCleanupConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { model.removeLocalData() }
        } message: {
            Text("将删除所有端点、诊断记录、生成的 OpenCode 配置和 RelayDock 保存到钥匙串中的 API Key。")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 11) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("RelayDock").font(.headline)
                    Text("Endpoint launcher").font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("配置", systemImage: "slider.horizontal.3")
                    .fontWeight(.medium)
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                Label("\(model.profiles.count) 个 Endpoint", systemImage: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 11).padding(.vertical, 8)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Button { model.configureOpenCode(launch: true) } label: {
                    Label("打开 OpenCode", systemImage: "terminal")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!model.openCodeInstalled)
                Button { model.openCursor() } label: {
                    Label("打开 Cursor", systemImage: "cursorarrow")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!model.cursorInstalled)
            }
            .buttonStyle(.borderless)

            Text("v\(model.currentVersion)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 218)
        .background(Color.white)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("配置").font(.largeTitle.bold())
            Text("一个配置管理多个 Endpoint、密钥与模型。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var endpointConfigurationCard: some View {
        cleanCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Endpoints").font(.title3.bold())
                        Text("每个 Endpoint 使用独立协议、地址、Key 和模型列表。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("添加 Endpoint", systemImage: "plus", action: attemptAddProfile)
                        .buttonStyle(.bordered)
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
                Toggle("启用", isOn: $model.draftProfile.isEnabled)
                    .toggleStyle(.switch).controlSize(.small)
            }
            formRow("名称") {
                TextField("例如 OpenAI Production", text: $model.draftProfile.displayName)
            }
            formRow("协议") {
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
                Toggle("使用 Azure 旧版 deployment URL", isOn: $model.draftProfile.azureDeploymentBasedURLs)
                if model.draftProfile.azureDeploymentBasedURLs {
                    Text("Azure 已停用旧版 deployment 列表接口；请手动添加 deployment ID，随后可一键验证。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            formRow("API Key") {
                SecureField("安全保存到 macOS Keychain", text: $model.apiKey)
            }

            Divider().padding(.vertical, 2)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Models").font(.headline)
                    Text("测试连接后会自动同步；也可以手动添加。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("添加", systemImage: "plus") { model.addModel() }
                    .buttonStyle(.borderless)
            }

            if model.draftProfile.models.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.slash").foregroundStyle(.secondary)
                    Text("还没有模型").fontWeight(.medium)
                    Text("点击“测试并获取模型”自动同步。")
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
                Button("保存") { model.saveSelectedProfile() }
                    .buttonStyle(.borderedProminent)
                Button("同步模型") { model.testEndpoint() }
                    .disabled(model.isBusy || usesLegacyAzureDeployments)
                    .help("测试 Endpoint 并自动获取模型")
                Button("一键验证全部") { showModelTestConfirmation = true }
                    .disabled(model.isBusy || model.draftProfile.models.isEmpty)
                Spacer()
                Menu {
                    Button("删除 Endpoint…", role: .destructive) { showDeleteConfirmation = true }
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
            TextField("模型 ID", text: route.modelID)
            TextField("显示名称（可选）", text: route.displayName)
            modelStateView(model.modelProbeStates[route.wrappedValue.id])
            Button(role: .destructive) { model.removeModel(route.wrappedValue.id) } label: {
                Image(systemName: "minus.circle")
            }.buttonStyle(.plain)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func modelStateView(_ state: ModelProbeState?) -> some View {
        switch state {
        case .testing:
            ProgressView().controlSize(.small).help("正在测试")
        case .available:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("可用")
        case let .failed(reason):
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help(reason)
        case nil:
            Image(systemName: "circle").foregroundStyle(.tertiary).help("尚未测试")
        }
    }

    private var launcherCard: some View {
        cleanCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Launchers").font(.title3.bold())
                HStack(spacing: 12) {
                    launcherTile(
                        title: "OpenCode",
                        detail: "写入独立配置并带上全部已启用 Endpoint 启动。",
                        installed: model.openCodeInstalled,
                        icon: "terminal",
                        actionTitle: "配置并打开",
                        action: { model.configureOpenCode(launch: true) }
                    )
                    launcherTile(
                        title: "Cursor",
                        detail: "一键打开 Cursor；普通启动不会注入第三方 Endpoint。",
                        installed: model.cursorInstalled,
                        icon: "cursorarrow",
                        actionTitle: "打开 Cursor",
                        action: model.openCursor
                    )
                }
                Text("Cursor 的第三方端点能力取决于 Cursor 本身；RelayDock 不会虚假声明普通启动已完成端点替换。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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
                    Text(installed ? "已安装" : "未找到")
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
                        Text("RelayDock \(release.version) 可用；安装前会校验 SHA-256、版本和 App 签名。")
                            .font(.caption).foregroundStyle(.secondary)
                        updateResultRow
                    } else {
                        updateResultRow
                    }
                }
                Spacer()
                Toggle("自动检查", isOn: $model.automaticUpdateChecks).toggleStyle(.switch).controlSize(.small)
                if model.availableRelease != nil {
                    if model.updateInstallerWasOpened {
                        VStack(alignment: .trailing, spacing: 4) {
                            Button("安装器已打开") {}.disabled(true)
                            Button("安装已取消？重新尝试") { model.resetUpdateInstallerHandoff() }
                                .buttonStyle(.link).font(.caption)
                        }
                    } else {
                        Button(model.isDownloadingUpdate ? "准备安装…" : "下载并安装…") { model.installAvailableUpdate() }
                            .disabled(model.isDownloadingUpdate)
                    }
                } else {
                    Button(model.isCheckingForUpdates ? "检查中…" : "检查更新") {
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
            Label("尚未检查更新", systemImage: "minus.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在检查 GitHub Release…")
            }
            .font(.caption).foregroundStyle(.secondary)
        case let .upToDate(date):
            Label("已是最新版本 · \(date.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case let .updateAvailable(version, checkedAt):
            Label("发现 v\(version) · \(checkedAt.formatted(date: .omitted, time: .shortened))", systemImage: "arrow.down.circle.fill")
                .font(.caption).foregroundStyle(.blue)
        case let .failed(message, checkedAt):
            Label("检查失败 · \(checkedAt.formatted(date: .omitted, time: .shortened)) · \(message)", systemImage: "exclamationmark.circle.fill")
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    private var probeCard: some View {
        cleanCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Cursor Network Probe", systemImage: "scope").font(.headline)
                    Spacer()
                    Text(model.verdict.title).font(.callout).foregroundStyle(verdictColor)
                }
                Text(model.verdict.explanation).font(.callout).foregroundStyle(.secondary)
                HStack {
                    if model.proxyRunning {
                        Label("127.0.0.1:\(model.proxyPort ?? 0)", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                        Button("停止", role: .destructive) { model.stopProbe() }
                    } else {
                        Button("启动探测代理") { model.startProbe() }
                    }
                    Spacer()
                    Button("通过代理打开 Cursor") { model.launchCursor(restart: false) }
                        .disabled(!model.proxyRunning || model.isBusy)
                    Button("重启并探测") { model.launchCursor(restart: true) }
                        .disabled(!model.proxyRunning || model.isBusy)
                }
            }
        }
    }

    private var diagnosticsCard: some View {
        cleanCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("最近连接").font(.headline)
                    Spacer()
                    Button("清除") { model.clearDiagnostics() }.disabled(model.events.isEmpty)
                }
                if model.events.isEmpty {
                    Text("暂无连接。通过 RelayDock 代理启动 Cursor 后，连接目标会显示在这里。")
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
            Button("清除本地数据…", role: .destructive) { showCleanupConfirmation = true }
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
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
            content().frame(maxWidth: .infinity)
        }
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

    private func performPendingNavigation(saveFirst: Bool) {
        guard let pendingNavigation else { return }
        if saveFirst, !model.saveSelectedProfile() {
            self.pendingNavigation = nil
            return
        }
        switch pendingNavigation {
        case .add: model.addProfile()
        case let .select(id): model.selectProfile(id)
        }
        self.pendingNavigation = nil
    }

    private var verdictColor: Color {
        switch model.verdict {
        case .waiting: return .secondary
        case .directAnthropic: return .green
        case .cursorBackendOnly: return .orange
        }
    }
}

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开 RelayDock") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Text("Endpoint：\(model.profiles.filter(\.isEnabled).count) 个已启用")
        Button("打开 OpenCode") { model.configureOpenCode(launch: true) }.disabled(!model.openCodeInstalled)
        Button("打开 Cursor") { model.openCursor() }.disabled(!model.cursorInstalled)
        Divider()
        Text(model.proxyRunning ? "探测代理：127.0.0.1:\(model.proxyPort ?? 0)" : "探测代理：已停止")
        if model.proxyRunning {
            Button("通过代理打开 Cursor") { model.launchCursor(restart: false) }
            Button("停止探测") { model.stopProbe() }
        } else {
            Button("启动探测") { model.startProbe() }
        }
        Divider()
        Button(model.isCheckingForUpdates ? "正在检查更新…" : "检查更新") {
            Task { await model.checkForUpdates() }
        }
        .disabled(model.isCheckingForUpdates)
        Button("退出 RelayDock") {
            model.stopProbe()
            NSApp.terminate(nil)
        }
    }
}
