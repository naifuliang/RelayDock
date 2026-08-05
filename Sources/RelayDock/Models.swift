import Foundation

struct EndpointProfile: Codable, Equatable {
    var baseURL: String = ""
    var displayName: String = "Sub2API"
}

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case openAICompatible
    case openAIResponses
    case azureOpenAI
    case anthropic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAICompatible: return "OpenAI Compatible"
        case .openAIResponses: return "OpenAI Responses"
        case .azureOpenAI: return "Azure OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    var openCodePackage: String {
        switch self {
        case .openAICompatible: return "@ai-sdk/openai-compatible"
        case .openAIResponses: return "@ai-sdk/openai"
        case .azureOpenAI: return "@ai-sdk/azure"
        case .anthropic: return "@ai-sdk/anthropic"
        }
    }
}

struct GatewayModel: Codable, Equatable, Identifiable {
    var id = UUID()
    var modelID: String = ""
    var displayName: String = ""
    var isEnabled = true
}

struct GatewayProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var displayName = "New Gateway"
    var provider: ProviderKind = .openAICompatible
    var baseURL = ""
    var isEnabled = true
    var models: [GatewayModel] = []
    var azureAPIVersion = "v1"
    var azureDeploymentBasedURLs = false

    static func migrated(from legacy: EndpointProfile) -> GatewayProfile {
        GatewayProfile(
            displayName: legacy.displayName,
            provider: .openAICompatible,
            baseURL: legacy.baseURL,
            models: []
        )
    }

    var providerID: String {
        "relaydock-" + id.uuidString.lowercased()
    }
}

struct GitHubRelease: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let browserDownloadURL: URL
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case digest
        }
    }

    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }

    var version: String { tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) }
}

enum VersionComparator {
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = components(candidate)
        let rhs = components(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func components(_ value: String) -> [Int] {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".")
            .map { component in
                Int(component.prefix { $0.isNumber }) ?? 0
            }
    }
}

enum ModelCatalogParser {
    static func modelIDs(from data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let items: [Any]
        if let array = object as? [Any] {
            items = array
        } else if let dictionary = object as? [String: Any] {
            items = (dictionary["data"] as? [Any])
                ?? (dictionary["models"] as? [Any])
                ?? (dictionary["deployments"] as? [Any])
                ?? (dictionary["value"] as? [Any])
                ?? []
        } else {
            items = []
        }

        var seen = Set<String>()
        return items.compactMap { item in
            let rawID: String?
            if let value = item as? String {
                rawID = value
            } else if let dictionary = item as? [String: Any] {
                guard isTextGenerationCandidate(dictionary) else { return nil }
                rawID = dictionary["id"] as? String
                    ?? dictionary["model"] as? String
                    ?? dictionary["model_id"] as? String
                    ?? dictionary["name"] as? String
            } else {
                rawID = nil
            }
            guard let id = rawID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty, isTextGenerationID(id), seen.insert(id).inserted else { return nil }
            return id
        }
    }

    static func nextCursor(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              dictionary["has_more"] as? Bool == true,
              let cursor = dictionary["last_id"] as? String,
              !cursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return cursor
    }

    private static func isTextGenerationCandidate(_ item: [String: Any]) -> Bool {
        if let capabilities = item["capabilities"] as? [String: Any] {
            let chat = capabilities["chat_completion"] as? Bool
            let completion = capabilities["completion"] as? Bool
            if let chat { return chat }
            if completion != nil { return false }
        }
        let type = (item["type"] as? String)?.lowercased() ?? ""
        let rawID = (item["id"] as? String)
            ?? (item["model"] as? String)
            ?? (item["model_id"] as? String)
            ?? (item["name"] as? String)
            ?? ""
        return isTextGenerationID("\(type) \(rawID)")
    }

    private static func isTextGenerationID(_ value: String) -> Bool {
        let searchable = value.lowercased()
        let nonTextMarkers = [
            "embedding", "moderation", "whisper", "transcri", "tts",
            "speech", "audio", "realtime", "dall-e", "image", "video",
            "sora", "rerank"
        ]
        return !nonTextMarkers.contains { searchable.contains($0) }
    }
}

struct ProxyEvent: Identifiable, Equatable {
    enum Kind: String {
        case connected
        case tunneled
        case failed
    }

    let id = UUID()
    let timestamp: Date
    let host: String
    let port: UInt16
    let kind: Kind
    let detail: String

    var isAnthropic: Bool {
        host == "api.anthropic.com" || host.hasSuffix(".anthropic.com")
    }
}

enum ProbeVerdict: Equatable {
    case waiting
    case directAnthropic
    case cursorBackendOnly

    var title: String {
        switch self {
        case .waiting: return "等待 Cursor 请求"
        case .directAnthropic: return "检测到 Anthropic 本机直连"
        case .cursorBackendOnly: return "目前只检测到 Cursor 后端"
        }
    }

    var explanation: String {
        switch self {
        case .waiting:
            return "通过 RelayDock 启动 Cursor 后，用 Anthropic BYOK 发送一条消息。"
        case .directAnthropic:
            return "这台机器上的 Cursor 直接连接 api.anthropic.com，可以继续启用定向 TLS Bridge。"
        case .cursorBackendOnly:
            return "请求可能由 Cursor 后端代发。继续发送一条 Anthropic BYOK 消息以确认。"
        }
    }
}

enum ConnectRequestParser {
    struct Request: Equatable {
        let host: String
        let port: UInt16
        let headerLength: Int
    }

    static func parse(_ data: Data) -> Request? {
        guard let marker = data.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: data[..<marker.upperBound], encoding: .utf8) else {
            return nil
        }

        let firstLine = header.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let components = firstLine.split(separator: " ")
        guard components.count >= 2, components[0].uppercased() == "CONNECT" else {
            return nil
        }

        let authority = String(components[1])
        if authority.hasPrefix("[") {
            guard let closing = authority.firstIndex(of: "]") else { return nil }
            let host = String(authority[authority.index(after: authority.startIndex)..<closing])
            let remainder = authority[authority.index(after: closing)...]
            let port: UInt16
            if remainder.first == ":" {
                guard let parsedPort = UInt16(remainder.dropFirst()), parsedPort > 0 else { return nil }
                port = parsedPort
            } else {
                port = 443
            }
            return Request(host: host.lowercased(), port: port, headerLength: marker.upperBound)
        }

        let pieces = authority.split(separator: ":", maxSplits: 1)
        let host = String(pieces[0]).lowercased()
        let port: UInt16
        if pieces.count == 2 {
            guard let parsedPort = UInt16(pieces[1]), parsedPort > 0 else { return nil }
            port = parsedPort
        } else {
            port = 443
        }
        guard !host.isEmpty else { return nil }
        return Request(host: host, port: port, headerLength: marker.upperBound)
    }

    static func hasCompleteHeader(_ data: Data) -> Bool {
        data.range(of: Data("\r\n\r\n".utf8)) != nil
    }
}

enum EndpointValidator {
    static func normalizedURL(from rawValue: String) -> URL? {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else { return nil }

        if scheme == "https" { return url }
        let loopbackHosts = Set(["127.0.0.1", "::1", "localhost"])
        if scheme == "http", loopbackHosts.contains(host) { return url }
        return nil
    }
}
