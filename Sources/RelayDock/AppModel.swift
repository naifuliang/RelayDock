import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var profile: EndpointProfile
    @Published var apiKey: String
    @Published private(set) var proxyRunning = false
    @Published private(set) var proxyPort: UInt16?
    @Published private(set) var events: [ProxyEvent] = []
    @Published private(set) var statusMessage = "准备就绪"
    @Published private(set) var isBusy = false

    private let defaults = UserDefaults.standard
    private var proxy: ProbeProxy?
    private var activeProxyToken: UUID?
    private static let profileKey = "endpointProfile"

    init() {
        if let data = defaults.data(forKey: Self.profileKey),
           let saved = try? JSONDecoder().decode(EndpointProfile.self, from: data) {
            profile = saved
        } else {
            profile = EndpointProfile()
        }
        apiKey = KeychainStore.loadAPIKey()
    }

    var cursorInstalled: Bool { CursorLauncher.isInstalled }

    var verdict: ProbeVerdict {
        if events.contains(where: { $0.isAnthropic }) { return .directAnthropic }
        if events.contains(where: { $0.host.contains("cursor.sh") || $0.host.contains("cursor.com") }) {
            return .cursorBackendOnly
        }
        return .waiting
    }

    func saveProfile() {
        do {
            guard let url = normalizedEndpointURL else {
                statusMessage = "端点地址无效"
                return
            }
            profile.baseURL = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let data = try JSONEncoder().encode(profile)
            defaults.set(data, forKey: Self.profileKey)
            try KeychainStore.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            statusMessage = "配置已安全保存"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func testEndpoint() {
        guard let base = normalizedEndpointURL else {
            statusMessage = "请先填写有效的 HTTPS 端点"
            return
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        isBusy = true
        statusMessage = "正在测试 /v1/models…"

        Task {
            defer { isBusy = false }
            do {
                let url: URL
                if base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "v1" {
                    url = base.appendingPathComponent("models")
                } else {
                    url = base.appendingPathComponent("v1/models")
                }
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
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
            defaults.removeObject(forKey: Self.profileKey)
            try KeychainStore.removeAll()
            profile = EndpointProfile()
            apiKey = ""
            events.removeAll()
            statusMessage = "RelayDock 本地配置和钥匙串凭据已清除"
        } catch {
            statusMessage = "清理失败：\(error.localizedDescription)"
        }
    }

    private var normalizedEndpointURL: URL? {
        EndpointValidator.normalizedURL(from: profile.baseURL)
    }
}

enum EndpointError: LocalizedError {
    case invalidResponse
    var errorDescription: String? { "端点响应无效" }
}
