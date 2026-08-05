import Foundation

struct EndpointProfile: Codable, Equatable {
    var baseURL: String = ""
    var displayName: String = "Sub2API"
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
