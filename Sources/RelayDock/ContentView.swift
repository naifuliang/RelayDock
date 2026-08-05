import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showCleanupConfirmation = false

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 18) {
                brand
                Label("Gateway", systemImage: "network")
                    .font(.headline)
                Label("Cursor Probe", systemImage: "scope")
                    .font(.headline)
                Spacer()
                Text("One endpoint. Every coding tool.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    gatewayCard
                    probeCard
                    diagnosticsCard
                    footer
                }
                .padding(26)
            }
        }
        .alert("清除 RelayDock 本地数据？", isPresented: $showCleanupConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { model.removeLocalData() }
        } message: {
            Text("将删除端点配置、诊断记录和 RelayDock 保存到钥匙串中的 API Key。当前版本不会安装系统证书。")
        }
    }

    private var brand: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("RelayDock").font(.title2.bold())
                Text("Endpoint launcher for macOS").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var gatewayCard: some View {
        GroupBox("Sub2API Gateway") {
            VStack(alignment: .leading, spacing: 14) {
                TextField("https://api.example.com", text: $model.profile.baseURL)
                    .textFieldStyle(.roundedBorder)
                SecureField("API Key（保存到 macOS Keychain）", text: $model.apiKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存配置") { model.saveProfile() }
                        .buttonStyle(.borderedProminent)
                    Button("测试端点") { model.testEndpoint() }
                        .disabled(model.isBusy)
                    Spacer()
                    Label(model.cursorInstalled ? "Cursor 已安装" : "未找到 Cursor", systemImage: model.cursorInstalled ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(model.cursorInstalled ? .green : .red)
                }
            }
            .padding(8)
        }
    }

    private var probeCard: some View {
        GroupBox("Cursor 网络链路探测") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: verdictIcon)
                        .font(.title2)
                        .foregroundStyle(verdictColor)
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
                        Button("启动探测代理") { model.startProbe() }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    Button("通过代理启动 Cursor") { model.launchCursor(restart: false) }
                        .disabled(!model.proxyRunning || model.isBusy)
                    Button("重启 Cursor 并探测") { model.launchCursor(restart: true) }
                        .disabled(!model.proxyRunning || model.isBusy)
                }
                Text("探测代理只记录 CONNECT 目标域名，HTTPS 内容保持加密；当前版本不会安装证书或解密流量。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        Image(systemName: "waveform.path.ecg")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("暂无连接").font(.headline)
                        Text("通过 RelayDock 启动 Cursor 后，连接目标会显示在这里。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                        .frame(height: 140)
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
        Text(model.proxyRunning ? "探测代理：127.0.0.1:\(model.proxyPort ?? 0)" : "探测代理：已停止")
        if model.proxyRunning {
            Button("启动 Cursor") { model.launchCursor(restart: false) }
            Button("停止探测") { model.stopProbe() }
        } else {
            Button("启动探测") { model.startProbe() }
        }
        Divider()
        Button("退出 RelayDock") {
            model.stopProbe()
            NSApp.terminate(nil)
        }
    }
}
