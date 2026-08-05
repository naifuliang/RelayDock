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
    @State private var pendingNavigation: PendingNavigation?

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                brand
                HStack {
                    Text("ENDPOINTS").font(.caption2.bold()).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: attemptAddProfile) { Image(systemName: "plus") }
                        .buttonStyle(.plain)
                        .help("添加端点")
                }
                VStack(spacing: 5) {
                    ForEach(model.profiles) { profile in
                        Button {
                            attemptSelectProfile(profile.id)
                        } label: {
                            HStack(spacing: 9) {
                                Circle()
                                    .fill(profile.isEnabled ? Color.green : Color.secondary.opacity(0.4))
                                    .frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.displayName).lineLimit(1)
                                    Text(profile.provider.title).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(profile.id == model.selectedProfileID ? Color.accentColor.opacity(0.14) : .clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
                Text("Many endpoints. Every coding tool.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .navigationSplitViewColumnWidth(min: 215, ideal: 235)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    gatewayCard
                    openCodeCard
                    updateCard
                    probeCard
                    diagnosticsCard
                    footer
                }
                .padding(26)
            }
        }
        .alert("删除这个端点？", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { model.deleteSelectedProfile() }
        } message: {
            Text("将删除该端点及其钥匙串 API Key，不会影响其他端点。")
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

    private var brand: some View {
        HStack(spacing: 11) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text("RelayDock").font(.title2.bold())
                Text("Endpoint launcher for macOS").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var gatewayCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Gateway", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.headline)
                    Spacer()
                    Toggle("启用", isOn: $model.draftProfile.isEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                LabeledContent("名称") {
                    TextField("例如 OpenAI Production", text: $model.draftProfile.displayName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                }
                LabeledContent("协议") {
                    Picker("", selection: $model.draftProfile.provider) {
                        ForEach(ProviderKind.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 420)
                }
                LabeledContent("Base URL") {
                    TextField(endpointPlaceholder, text: $model.draftProfile.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                }
                if model.draftProfile.provider == .azureOpenAI {
                    LabeledContent("API Version") {
                        TextField("v1", text: $model.draftProfile.azureAPIVersion)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 420)
                    }
                    Toggle("使用 Azure 旧版 deployment URL", isOn: $model.draftProfile.azureDeploymentBasedURLs)
                }
                LabeledContent("API Key") {
                    SecureField("保存到 macOS Keychain", text: $model.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                }

                Divider()
                HStack {
                    Text("Models").font(.headline)
                    Spacer()
                    Button("添加模型", systemImage: "plus") { model.addModel() }
                }
                if model.draftProfile.models.isEmpty {
                    Text("还没有模型。添加模型 ID 后，它们会分别出现在 OpenCode 的模型选择器中。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 8) {
                        ForEach($model.draftProfile.models) { $route in
                            HStack {
                                Toggle("", isOn: $route.isEnabled).labelsHidden().toggleStyle(.checkbox)
                                TextField("模型 ID，例如 gpt-5", text: $route.modelID)
                                    .textFieldStyle(.roundedBorder)
                                TextField("显示名称（可选）", text: $route.displayName)
                                    .textFieldStyle(.roundedBorder)
                                Button(role: .destructive) { model.removeModel(route.id) } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Divider()
                HStack {
                    Button("保存端点") { model.saveSelectedProfile() }
                        .buttonStyle(.borderedProminent)
                    Button("测试模型接口") { model.testEndpoint() }
                        .disabled(model.isBusy)
                    Spacer()
                    Button("删除端点…", role: .destructive) { showDeleteConfirmation = true }
                        .disabled(model.profiles.count <= 1)
                }
            }
            .padding(8)
        }
    }

    private var openCodeCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("OpenCode", systemImage: "terminal")
                        .font(.headline)
                    Spacer()
                    Label(model.openCodeInstalled ? "已安装" : "未找到", systemImage: model.openCodeInstalled ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(model.openCodeInstalled ? .green : .orange)
                }
                Text("RelayDock 会生成独立的 OPENCODE_CONFIG，不覆盖你现有的全局配置。每个启用的 Gateway 会成为一个 provider，每个模型都可以单独选择。密钥写入权限为 600 的 RelayDock 私有文件，并由 OpenCode 的 {file:…} 读取。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("生成配置") { model.configureOpenCode(launch: false) }
                    Button("配置并启动 OpenCode") { model.configureOpenCode(launch: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.openCodeInstalled)
                }
            }
            .padding(8)
        }
    }

    private var updateCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                    Text("v\(model.currentVersion)").foregroundStyle(.secondary)
                    Spacer()
                    Toggle("启动时自动检查", isOn: $model.automaticUpdateChecks)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                if let release = model.availableRelease {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("RelayDock \(release.version) 可用").font(.headline)
                            Text("安装包将从 GitHub Release 下载并校验 SHA-256。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.isDownloadingUpdate ? "正在下载…" : "下载并打开 DMG") {
                            model.downloadAvailableUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isDownloadingUpdate)
                    }
                } else {
                    HStack {
                        Text("自动检查最多每天一次，也可以手动检查。")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button(model.isCheckingForUpdates ? "正在检查…" : "检查更新") {
                            Task { await model.checkForUpdates() }
                        }
                        .disabled(model.isCheckingForUpdates)
                    }
                }
            }
            .padding(8)
        }
    }

    private var probeCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Cursor Network Probe", systemImage: "scope").font(.headline)
                    Spacer()
                    Label(model.cursorInstalled ? "Cursor 已安装" : "未找到 Cursor", systemImage: model.cursorInstalled ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(model.cursorInstalled ? .green : .red)
                }
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: verdictIcon).font(.title2).foregroundStyle(verdictColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.verdict.title).font(.headline)
                        Text(model.verdict.explanation).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Divider()
                HStack {
                    if model.proxyRunning {
                        Label("127.0.0.1:\(model.proxyPort ?? 0)", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                        Button("停止探测", role: .destructive) { model.stopProbe() }
                    } else {
                        Button("启动探测代理") { model.startProbe() }.buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    Button("通过代理启动 Cursor") { model.launchCursor(restart: false) }
                        .disabled(!model.proxyRunning || model.isBusy)
                    Button("重启 Cursor 并探测") { model.launchCursor(restart: true) }
                        .disabled(!model.proxyRunning || model.isBusy)
                }
                Text("Cursor 目前仍是网络能力探测：不会把上面的多个 Gateway 虚假声明为 Cursor 原生支持。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private var diagnosticsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("最近连接").font(.headline)
                    Spacer()
                    Button("清除") { model.clearDiagnostics() }.disabled(model.events.isEmpty)
                }
                if model.events.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.path.ecg").font(.title).foregroundStyle(.secondary)
                        Text("暂无连接").font(.headline)
                        Text("通过 RelayDock 启动 Cursor 后，连接目标会显示在这里。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).frame(height: 120)
                } else {
                    LazyVStack(spacing: 0) {
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
                            .padding(.vertical, 7)
                            Divider()
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private var footer: some View {
        HStack {
            Text(model.statusMessage).foregroundStyle(.secondary)
            Spacer()
            Button("清除本地数据…", role: .destructive) { showCleanupConfirmation = true }
        }
        .font(.callout)
    }

    private var endpointPlaceholder: String {
        switch model.draftProfile.provider {
        case .azureOpenAI: return "https://resource.openai.azure.com/openai"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openAICompatible, .openAIResponses: return "https://api.example.com/v1"
        }
    }

    private func attemptSelectProfile(_ id: UUID) {
        guard id != model.selectedProfileID else { return }
        if model.hasUnsavedProfileChanges {
            pendingNavigation = .select(id)
            showUnsavedChanges = true
        } else {
            model.selectProfile(id)
        }
    }

    private func attemptAddProfile() {
        if model.hasUnsavedProfileChanges {
            pendingNavigation = .add
            showUnsavedChanges = true
        } else {
            model.addProfile()
        }
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

    private var verdictIcon: String {
        switch model.verdict {
        case .waiting: return "hourglass"
        case .directAnthropic: return "checkmark.shield.fill"
        case .cursorBackendOnly: return "exclamationmark.triangle.fill"
        }
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
        Text("端点：\(model.profiles.filter(\.isEnabled).count) 个已启用")
        Button("启动 OpenCode") { model.configureOpenCode(launch: true) }
            .disabled(!model.openCodeInstalled)
        Divider()
        Text(model.proxyRunning ? "探测代理：127.0.0.1:\(model.proxyPort ?? 0)" : "探测代理：已停止")
        if model.proxyRunning {
            Button("启动 Cursor") { model.launchCursor(restart: false) }
            Button("停止探测") { model.stopProbe() }
        } else {
            Button("启动探测") { model.startProbe() }
        }
        Divider()
        Button("检查更新") { Task { await model.checkForUpdates() } }
        Button("退出 RelayDock") {
            model.stopProbe()
            NSApp.terminate(nil)
        }
    }
}
