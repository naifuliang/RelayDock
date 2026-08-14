import CFNetwork
import Foundation
import XCTest
@testable import RelayDock

final class UpstreamProxyTests: XCTestCase {
    func testExplicitDirectResolverNeverConsultsInheritedProxyState() throws {
        XCTAssertEqual(
            try UpstreamProxyResolver.direct.route(to: URL(string: "https://[::1]:443")!),
            .direct
        )
    }
    func testEnvironmentHTTPSProxyIsPreservedWithBasicAuthentication() throws {
        let route = try XCTUnwrap(UpstreamProxyResolver.environmentRoute(
            to: XCTUnwrap(URL(string: "https://api.anthropic.com/v1/messages")),
            environment: ["HTTPS_PROXY": "http://user:pass@127.0.0.1:7890"]
        ))
        XCTAssertEqual(route, .httpProxy(HTTPUpstreamProxy(
            host: "127.0.0.1",
            port: 7890,
            authorizationHeader: "Basic dXNlcjpwYXNz",
            username: "user",
            password: "pass"
        )))
    }

    func testRelayDockURLSessionUsesTheSameResolvedProxy() throws {
        let resolver = UpstreamProxyResolver(
            environment: ["HTTPS_PROXY": "http://127.0.0.1:7897"],
            systemSettings: [:]
        )
        let session = try RelayDockNetwork.session(
            for: XCTUnwrap(URL(string: "https://api.github.com/")),
            resolver: resolver
        )
        defer { session.invalidateAndCancel() }
        let dictionary = try XCTUnwrap(session.configuration.connectionProxyDictionary)
        XCTAssertEqual(dictionary[kCFNetworkProxiesHTTPSProxy] as? String, "127.0.0.1")
        XCTAssertEqual(dictionary[kCFNetworkProxiesHTTPSPort] as? Int, 7897)
        XCTAssertEqual(dictionary[kCFNetworkProxiesHTTPSEnable] as? Bool, true)
    }

    func testNoProxyPreservesExistingBypassRules() throws {
        let route = try UpstreamProxyResolver.environmentRoute(
            to: XCTUnwrap(URL(string: "https://service.internal.example/v1")),
            environment: [
                "HTTPS_PROXY": "http://127.0.0.1:7890",
                "NO_PROXY": ".internal.example"
            ]
        )
        XCTAssertEqual(route, .direct)
        XCTAssertEqual(try UpstreamProxyResolver.environmentRoute(
            to: XCTUnwrap(URL(string: "https://[::1]:443/")),
            environment: ["HTTPS_PROXY": "http://127.0.0.1:7890", "NO_PROXY": "[::1]:443"]
        ), .direct)
        XCTAssertEqual(try UpstreamProxyResolver.environmentRoute(
            to: XCTUnwrap(URL(string: "https://api.github.com/")),
            environment: ["HTTPS_PROXY": "http://127.0.0.1:7890", "NO_PROXY": "api.github.com:443"]
        ), .direct)
    }

    func testRedirectPolicyFailsClosedWhenRouteChanges() throws {
        let resolver = UpstreamProxyResolver(
            environment: [
                "HTTPS_PROXY": "http://127.0.0.1:7897",
                "NO_PROXY": "initial.example"
            ],
            systemSettings: [:]
        )
        let policy = RelayDockRedirectPolicy(resolver: resolver, initialRoute: .direct)
        XCTAssertTrue(policy.permitsRedirect(to: URL(string: "https://initial.example/next")!))
        XCTAssertFalse(policy.permitsRedirect(to: URL(string: "https://asset.example/file")!))

        let proxiedPolicy = RelayDockRedirectPolicy(
            resolver: resolver,
            initialRoute: .httpProxy(HTTPUpstreamProxy(
                host: "127.0.0.1", port: 7897, authorizationHeader: nil
            ))
        )
        XCTAssertFalse(proxiedPolicy.permitsRedirect(to: URL(string: "https://initial.example/direct")!))
        XCTAssertTrue(proxiedPolicy.permitsRedirect(to: URL(string: "https://asset.example/file")!))
    }

    func testConnectResponsePreservesLargeCoalescedTunnelBytes() {
        let leftover = Data(repeating: 0x16, count: 32 * 1024)
        var response = Data("HTTP/1.1 200 Connection Established\r\nProxy-Agent: test\r\n\r\n".utf8)
        response.append(leftover)

        XCTAssertEqual(
            HTTPProxyConnectResponseParser.parse(response),
            .established(leftover: leftover)
        )
        XCTAssertEqual(
            HTTPProxyConnectResponseParser.parse(Data(repeating: 0x41, count: 16 * 1024 + 1)),
            .malformed
        )
    }

    func testHTTPProxyIsUsedAsFallbackForHTTPSDestination() throws {
        let route = try UpstreamProxyResolver.environmentRoute(
            to: XCTUnwrap(URL(string: "https://api.anthropic.com/")),
            environment: ["HTTP_PROXY": "http://127.0.0.1:7897"]
        )
        XCTAssertEqual(route, .httpProxy(HTTPUpstreamProxy(
            host: "127.0.0.1", port: 7897, authorizationHeader: nil
        )))
    }

    func testHTTPDestinationPrefersHTTPProxyWhenBothDiffer() throws {
        let route = try UpstreamProxyResolver.environmentRoute(
            to: XCTUnwrap(URL(string: "http://catalog.example/models")),
            environment: [
                "HTTP_PROXY": "http://127.0.0.1:7001",
                "HTTPS_PROXY": "http://127.0.0.1:7002"
            ]
        )
        XCTAssertEqual(route, .httpProxy(HTTPUpstreamProxy(
            host: "127.0.0.1", port: 7001, authorizationHeader: nil
        )))
    }

    func testSystemHTTPProxyDictionaryBecomesConnectUpstream() throws {
        let route = try UpstreamProxyResolver.route(fromSystemProxyDictionaries: [[
            kCFProxyTypeKey: kCFProxyTypeHTTP,
            kCFProxyHostNameKey: "127.0.0.1",
            kCFProxyPortNumberKey: 6152
        ]])
        XCTAssertEqual(route, .httpProxy(HTTPUpstreamProxy(
            host: "127.0.0.1",
            port: 6152,
            authorizationHeader: nil
        )))
    }

    func testUnsupportedSystemProxyModesFailClosed() {
        XCTAssertThrowsError(try UpstreamProxyResolver.route(fromSystemProxyDictionaries: [[
            kCFProxyTypeKey: kCFProxyTypeSOCKS,
            kCFProxyHostNameKey: "127.0.0.1",
            kCFProxyPortNumberKey: 1080
        ]])) { error in
            guard case UpstreamProxyError.unsupportedSOCKS = error else {
                return XCTFail("Expected fail-closed SOCKS error, got \(error)")
            }
        }
        XCTAssertThrowsError(try UpstreamProxyResolver.environmentRoute(
            to: URL(string: "https://api.anthropic.com/")!,
            environment: ["HTTPS_PROXY": "https://127.0.0.1:8443"]
        )) { error in
            guard case UpstreamProxyError.unsupportedTLSProxy = error else {
                return XCTFail("Expected fail-closed TLS-proxy error, got \(error)")
            }
        }
        XCTAssertThrowsError(try UpstreamProxyResolver.route(fromSystemProxyDictionaries: [[
            kCFProxyTypeKey: kCFProxyTypeAutoConfigurationURL
        ]])) { error in
            guard case UpstreamProxyError.unsupportedPAC = error else {
                return XCTFail("Expected fail-closed PAC error, got \(error)")
            }
        }
    }
}
