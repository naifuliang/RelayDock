import CFNetwork
import Foundation

struct HTTPUpstreamProxy: Equatable, Sendable {
    let host: String
    let port: Int
    let authorizationHeader: String?
    let username: String?
    let password: String?

    init(
        host: String,
        port: Int,
        authorizationHeader: String?,
        username: String? = nil,
        password: String? = nil
    ) {
        self.host = host
        self.port = port
        self.authorizationHeader = authorizationHeader
        self.username = username
        self.password = password
    }
}

enum UpstreamNetworkRoute: Equatable, Sendable {
    case direct
    case httpProxy(HTTPUpstreamProxy)
}

struct UpstreamProxyResolver: @unchecked Sendable {
    private let environment: [String: String]
    private let systemSettings: [AnyHashable: Any]
    private let fixedRoute: UpstreamNetworkRoute?

    static let direct = UpstreamProxyResolver(fixedRoute: .direct)

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        systemSettings: [AnyHashable: Any]? = nil
    ) {
        self.environment = environment
        self.fixedRoute = nil
        self.systemSettings = systemSettings
            ?? (CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [AnyHashable: Any] ?? [:])
    }

    private init(fixedRoute: UpstreamNetworkRoute) {
        environment = [:]
        systemSettings = [:]
        self.fixedRoute = fixedRoute
    }

    func route(to url: URL) throws -> UpstreamNetworkRoute {
        if let fixedRoute { return fixedRoute }
        if let environmentRoute = try Self.environmentRoute(to: url, environment: environment) {
            return environmentRoute
        }
        let proxies = CFNetworkCopyProxiesForURL(url as CFURL, systemSettings as CFDictionary)
            .takeRetainedValue() as NSArray
        let dictionaries = proxies.compactMap { $0 as? [AnyHashable: Any] }
        return try Self.route(fromSystemProxyDictionaries: dictionaries)
    }

    static func environmentRoute(
        to url: URL,
        environment: [String: String]
    ) throws -> UpstreamNetworkRoute? {
        guard let host = url.host else { return nil }
        let noProxy = environment["NO_PROXY"] ?? environment["no_proxy"] ?? ""
        let effectivePort = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        if noProxyMatches(host: host, port: effectivePort, rules: noProxy) { return .direct }
        let raw: String?
        if url.scheme?.lowercased() == "http" {
            raw = environment["HTTP_PROXY"]
                ?? environment["http_proxy"]
                ?? environment["ALL_PROXY"]
                ?? environment["all_proxy"]
        } else {
            raw = environment["HTTPS_PROXY"]
                ?? environment["https_proxy"]
                ?? environment["HTTP_PROXY"]
                ?? environment["http_proxy"]
                ?? environment["ALL_PROXY"]
                ?? environment["all_proxy"]
        }
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try parseProxyURL(raw)
    }

    static func route(
        fromSystemProxyDictionaries dictionaries: [[AnyHashable: Any]]
    ) throws -> UpstreamNetworkRoute {
        guard let first = dictionaries.first else { return .direct }
        let type = first[kCFProxyTypeKey] as? String
        if type == kCFProxyTypeNone as String? { return .direct }
        if type == kCFProxyTypeHTTP as String? || type == kCFProxyTypeHTTPS as String? {
            guard let host = first[kCFProxyHostNameKey] as? String,
                  let portNumber = first[kCFProxyPortNumberKey] as? NSNumber,
                  !host.isEmpty,
                  (1...65_535).contains(portNumber.intValue) else {
                throw UpstreamProxyError.invalidSystemProxy
            }
            return .httpProxy(HTTPUpstreamProxy(
                host: host,
                port: portNumber.intValue,
                authorizationHeader: nil
            ))
        }
        if type == kCFProxyTypeSOCKS as String? { throw UpstreamProxyError.unsupportedSOCKS }
        if type == kCFProxyTypeAutoConfigurationURL as String?
            || type == kCFProxyTypeAutoConfigurationJavaScript as String? {
            throw UpstreamProxyError.unsupportedPAC
        }
        throw UpstreamProxyError.invalidSystemProxy
    }

    private static func parseProxyURL(_ rawValue: String) throws -> UpstreamNetworkRoute {
        let value = rawValue.contains("://") ? rawValue : "http://\(rawValue)"
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty else { throw UpstreamProxyError.invalidEnvironmentProxy }
        guard scheme == "http" else {
            if scheme == "https" { throw UpstreamProxyError.unsupportedTLSProxy }
            if scheme.hasPrefix("socks") { throw UpstreamProxyError.unsupportedSOCKS }
            throw UpstreamProxyError.invalidEnvironmentProxy
        }
        // HTTPS_PROXY conventionally names the proxy for HTTPS destinations;
        // the connection to a local/system HTTP proxy itself remains plaintext.
        let port = components.port ?? 80
        var authorization: String?
        var decodedUser: String?
        var decodedPassword: String?
        if let user = components.user {
            decodedUser = user.removingPercentEncoding ?? user
            decodedPassword = components.password?.removingPercentEncoding ?? components.password ?? ""
            authorization = "Basic \(Data("\(decodedUser!):\(decodedPassword!)".utf8).base64EncodedString())"
        }
        return .httpProxy(HTTPUpstreamProxy(
            host: host,
            port: port,
            authorizationHeader: authorization,
            username: decodedUser,
            password: decodedPassword
        ))
    }

    private static func noProxyMatches(host: String, port: Int?, rules: String) -> Bool {
        let lowerHost = host.lowercased()
        for rawRule in rules.split(separator: ",") {
            var rule = rawRule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if rule == "*" { return true }
            if rule.hasPrefix("["), let closingBracket = rule.firstIndex(of: "]") {
                let bracketedHost = String(rule[rule.index(after: rule.startIndex)..<closingBracket])
                let remainder = rule[rule.index(after: closingBracket)...]
                if remainder.hasPrefix(":"), let candidatePort = Int(remainder.dropFirst()) {
                    guard candidatePort == port else { continue }
                } else if !remainder.isEmpty {
                    continue
                }
                rule = bracketedHost
            } else if rule.filter({ $0 == ":" }).count == 1,
                      let colon = rule.lastIndex(of: ":") {
                let candidatePort = Int(rule[rule.index(after: colon)...])
                if candidatePort != nil {
                    guard candidatePort == port else { continue }
                    rule = String(rule[..<colon])
                }
            }
            if rule.hasPrefix("*.") { rule.removeFirst(2) }
            rule = rule.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !rule.isEmpty, lowerHost == rule || lowerHost.hasSuffix(".\(rule)") { return true }
        }
        return false
    }
}

enum RelayDockNetwork {
    static func session(
        for url: URL,
        resolver: UpstreamProxyResolver = UpstreamProxyResolver()
    ) throws -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        let initialRoute = try resolver.route(to: url)
        switch initialRoute {
        case .direct:
            // The resolver has already applied NO_PROXY and macOS exception
            // rules. An empty dictionary prevents a second, divergent choice.
            configuration.connectionProxyDictionary = [:]
        case let .httpProxy(proxy):
            var dictionary: [AnyHashable: Any] = [
                kCFNetworkProxiesHTTPEnable: true,
                kCFNetworkProxiesHTTPProxy: proxy.host,
                kCFNetworkProxiesHTTPPort: proxy.port,
                kCFNetworkProxiesHTTPSEnable: true,
                kCFNetworkProxiesHTTPSProxy: proxy.host,
                kCFNetworkProxiesHTTPSPort: proxy.port
            ]
            if let username = proxy.username {
                dictionary[kCFProxyUsernameKey] = username
                dictionary[kCFProxyPasswordKey] = proxy.password ?? ""
            }
            configuration.connectionProxyDictionary = dictionary
        }
        let delegate = RelayDockRedirectPolicy(resolver: resolver, initialRoute: initialRoute)
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
}

final class RelayDockRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let resolver: UpstreamProxyResolver
    private let initialRoute: UpstreamNetworkRoute

    init(resolver: UpstreamProxyResolver, initialRoute: UpstreamNetworkRoute) {
        self.resolver = resolver
        self.initialRoute = initialRoute
    }

    func permitsRedirect(to url: URL) -> Bool {
        (try? resolver.route(to: url)) == initialRoute
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, permitsRedirect(to: url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum UpstreamProxyError: LocalizedError {
    case invalidEnvironmentProxy
    case invalidSystemProxy
    case unsupportedSOCKS
    case unsupportedTLSProxy
    case unsupportedPAC
    case connectRejected(Int)
    case malformedConnectResponse
    case connectTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidEnvironmentProxy: return "本地 HTTPS_PROXY/ALL_PROXY 配置无效；RelayDock 已停止，未绕过代理。"
        case .invalidSystemProxy: return "macOS 默认代理配置无效；RelayDock 已停止，未绕过代理。"
        case .unsupportedSOCKS: return "当前版本尚不能安全链式转发 SOCKS 默认代理；RelayDock 已停止，未改为直连。"
        case .unsupportedTLSProxy: return "当前版本尚不能安全链式转发 TLS 加密的上游代理；请使用本地代理提供的 HTTP CONNECT 端口。"
        case .unsupportedPAC: return "当前版本尚不能安全执行 PAC 默认代理；RelayDock 已停止，未改为直连。"
        case let .connectRejected(status): return "本地默认代理拒绝 CONNECT（HTTP \(status)）。"
        case .malformedConnectResponse: return "本地默认代理返回了无效的 CONNECT 响应。"
        case .connectTimedOut: return "连接本地默认代理超时；RelayDock 已停止，未绕过代理。"
        }
    }
}
