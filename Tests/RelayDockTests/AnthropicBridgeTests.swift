import Foundation
import NIO
import NIOHTTP1
@preconcurrency import NIOSSL
import XCTest
@testable import RelayDock

final class AnthropicBridgeTests: XCTestCase {
    func testRewritesAnthropicPathUnderUnversionedGatewayBase() throws {
        let base = try XCTUnwrap(URL(string: "https://gateway.example/anthropic"))
        XCTAssertEqual(
            AnthropicBridgeRequestRewriter.upstreamURI(
                incomingURI: "/v1/messages?beta=true", baseURL: base
            ),
            "/anthropic/v1/messages?beta=true"
        )
    }

    func testAvoidsDuplicatingVersionedGatewayBase() throws {
        let base = try XCTUnwrap(URL(string: "https://gateway.example/anthropic/v1"))
        XCTAssertEqual(
            AnthropicBridgeRequestRewriter.upstreamURI(incomingURI: "/v1/messages", baseURL: base),
            "/anthropic/v1/messages"
        )
    }

    func testReplacesClientCredentialsAndPreservesAnthropicHeaders() throws {
        let route = try AnthropicBridgeRoute(
            baseURL: XCTUnwrap(URL(string: "https://gateway.example/anthropic")),
            apiKey: "upstream-key"
        )
        var headers = HTTPHeaders()
        headers.add(name: "host", value: "api.anthropic.com")
        headers.add(name: "x-api-key", value: "cursor-key")
        headers.add(name: "authorization", value: "Bearer cursor-key")
        headers.add(name: "anthropic-version", value: "2025-01-01")
        headers.add(name: "content-type", value: "application/json")
        headers.add(name: "connection", value: "keep-alive, x-private-hop")
        headers.add(name: "keep-alive", value: "timeout=5")
        headers.add(name: "x-private-hop", value: "remove-me")
        headers.add(name: "proxy-authorization", value: "Basic remove-me")
        let rewritten = AnthropicBridgeRequestRewriter.upstreamHead(
            HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/messages", headers: headers),
            route: route
        )
        XCTAssertEqual(rewritten.headers.first(name: "host"), "gateway.example")
        XCTAssertEqual(rewritten.headers.first(name: "x-api-key"), "upstream-key")
        XCTAssertEqual(rewritten.headers.first(name: "authorization"), "Bearer upstream-key")
        XCTAssertEqual(rewritten.headers.first(name: "anthropic-version"), "2025-01-01")
        XCTAssertEqual(rewritten.headers.first(name: "content-type"), "application/json")
        XCTAssertEqual(rewritten.headers.first(name: "connection"), "close")
        XCTAssertNil(rewritten.headers.first(name: "keep-alive"))
        XCTAssertNil(rewritten.headers.first(name: "x-private-hop"))
        XCTAssertNil(rewritten.headers.first(name: "proxy-authorization"))
    }

    func testOfficialAnthropicUpstreamUsesNativeAPIKeyOnly() throws {
        let route = try AnthropicBridgeRoute(
            baseURL: XCTUnwrap(URL(string: "https://api.anthropic.com/v1")),
            apiKey: "official-key"
        )
        let rewritten = AnthropicBridgeRequestRewriter.upstreamHead(
            HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/messages"),
            route: route
        )
        XCTAssertEqual(rewritten.headers.first(name: "x-api-key"), "official-key")
        XCTAssertNil(rewritten.headers.first(name: "authorization"))
    }

    func testLocalClientMustPresentSelectedEndpointKey() {
        var authorizedHeaders = HTTPHeaders()
        authorizedHeaders.add(name: "x-api-key", value: "selected-secret")
        let authorized = HTTPRequestHead(
            version: .http1_1, method: .POST, uri: "/v1/messages", headers: authorizedHeaders
        )
        XCTAssertTrue(AnthropicBridgeClientAuthentication.isAuthorized(
            authorized,
            expectedAPIKey: "selected-secret"
        ))

        var rejectedHeaders = HTTPHeaders()
        rejectedHeaders.add(name: "x-api-key", value: "different-secret")
        let rejected = HTTPRequestHead(
            version: .http1_1, method: .POST, uri: "/v1/messages", headers: rejectedHeaders
        )
        XCTAssertFalse(AnthropicBridgeClientAuthentication.isAuthorized(
            rejected,
            expectedAPIKey: "selected-secret"
        ))
        XCTAssertFalse(AnthropicBridgeClientAuthentication.isAuthorized(
            HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/messages"),
            expectedAPIKey: "selected-secret"
        ))
    }

    func testBridgeAllowsOnlyExplicitAnthropicPOSTRoutes() {
        XCTAssertTrue(AnthropicBridgeRequestValidator.isAllowed(HTTPRequestHead(
            version: .http1_1, method: .POST, uri: "/v1/messages?beta=true"
        )))
        XCTAssertTrue(AnthropicBridgeRequestValidator.isAllowed(HTTPRequestHead(
            version: .http1_1, method: .POST, uri: "/v1/messages/count_tokens"
        )))
        XCTAssertFalse(AnthropicBridgeRequestValidator.isAllowed(HTTPRequestHead(
            version: .http1_1, method: .GET, uri: "/v1/messages"
        )))
        XCTAssertFalse(AnthropicBridgeRequestValidator.isAllowed(HTTPRequestHead(
            version: .http1_1, method: .POST, uri: "/v1/../../admin"
        )))
        XCTAssertFalse(AnthropicBridgeRequestValidator.isAllowed(HTTPRequestHead(
            version: .http1_1, method: .POST, uri: "/v1/%2e%2e/admin"
        )))
        XCTAssertFalse(AnthropicBridgeRequestValidator.isAllowed(HTTPRequestHead(
            version: .http1_1, method: .POST, uri: "https://api.anthropic.com/v1/messages"
        )))
    }

    func testEndToEndConnectTLSCredentialRewriteAndStreamingResponse() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockBridgeE2E-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let material = try BridgeCertificateManager.ensureMaterial(directory: root)
        let capture = RequestCapture()
        let upstream = try TestAnthropicUpstream(material: material, capture: capture)
        defer { upstream.stop() }
        let upstreamProxy = try TestHTTPConnectProxy()
        defer { upstreamProxy.stop() }
        let route = try AnthropicBridgeRoute(
            baseURL: XCTUnwrap(URL(string: "https://127.0.0.1:\(upstream.port)/anthropic")),
            apiKey: "sub2api-upstream-key",
            verifyUpstreamTLS: false
        )
        let proxy = AnthropicBridgeProxy(
            route: route,
            material: material,
            upstreamProxyResolver: UpstreamProxyResolver(
                environment: ["HTTPS_PROXY": "http://127.0.0.1:\(upstreamProxy.port)"],
                systemSettings: [:]
            ),
            onEvent: { capture.storeEvent($0.detail) },
            onState: { _, _ in }
        )
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "s_client", "-quiet", "-verify_return_error",
            "-proxy", "127.0.0.1:\(proxyPort)",
            "-connect", "api.anthropic.com:443",
            "-servername", "api.anthropic.com",
            "-CAfile", material.certificateURL.path
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let request = """
        POST /v1/messages HTTP/1.1\r
        Host: api.anthropic.com\r
        x-api-key: sub2api-upstream-key\r
        anthropic-version: 2023-06-01\r
        content-type: application/json\r
        content-length: 2\r
        connection: close\r
        \r
        {}
        """
        input.fileHandleForWriting.write(Data(request.utf8))
        try input.fileHandleForWriting.close()
        let responseData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let response = String(decoding: responseData, as: UTF8.self)
        XCTAssertTrue(response.contains("HTTP/1.1 200 OK"), "\(response)\nEvents: \(capture.events)")
        XCTAssertTrue(response.contains("data: first"), response)
        XCTAssertTrue(response.contains("data: second"), response)

        let head = try XCTUnwrap(capture.head)
        XCTAssertEqual(head.uri, "/anthropic/v1/messages")
        XCTAssertEqual(head.headers.first(name: "x-api-key"), "sub2api-upstream-key")
        XCTAssertEqual(head.headers.first(name: "authorization"), "Bearer sub2api-upstream-key")
        XCTAssertEqual(upstreamProxy.targets, ["127.0.0.1:\(upstream.port)"])
    }

    func testCursorBundledNodeFetchUsesRelayDockProxy() throws {
        guard ProcessInfo.processInfo.environment["RELAYDOCK_CURSOR_NODE_PROXY_TEST"] == "1" else {
            throw XCTSkip("Set RELAYDOCK_CURSOR_NODE_PROXY_TEST=1 for the installed-Cursor runtime test.")
        }
        guard FileManager.default.isExecutableFile(atPath: CursorLauncher.executableURL.path) else {
            throw XCTSkip("Cursor is not installed in /Applications.")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockCursorNodeE2E-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let material = try CursorNodeBridgeCertificateManager.ensureMaterial(directory: root)
        let capture = RequestCapture()
        let upstream = try TestAnthropicUpstream(material: material, capture: capture)
        defer { upstream.stop() }
        let route = try AnthropicBridgeRoute(
            baseURL: XCTUnwrap(URL(string: "https://127.0.0.1:\(upstream.port)/anthropic")),
            apiKey: "sub2api-upstream-key",
            verifyUpstreamTLS: false
        )
        let proxy = AnthropicBridgeProxy(
            route: route,
            material: material,
            onEvent: { capture.storeEvent($0.detail) },
            onState: { _, _ in }
        )
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let script = #"""
        fetch("https://api.anthropic.com/v1/messages", {
          method: "POST",
          headers: {
            "x-api-key": "sub2api-upstream-key",
            "anthropic-version": "2023-06-01",
            "content-type": "application/json"
          },
          body: "{}"
        }).then(async response => {
          console.log(`STATUS:${response.status}`)
          console.log(await response.text())
        }).catch(error => {
          console.error(error)
          process.exitCode = 1
        })
        """#
        let process = Process()
        process.executableURL = CursorLauncher.executableURL
        process.arguments = ["-e", script]
        var environment = CursorLauncher.proxyEnvironment(
            port: proxyPort,
            nodeTrustAnchorURL: material.nodeTrustAnchorURL,
            inheriting: [:]
        )
        environment["ELECTRON_RUN_AS_NODE"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let responseData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let response = String(decoding: responseData, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "\(response)\nEvents: \(capture.events)")
        XCTAssertTrue(response.contains("STATUS:200"), response)
        XCTAssertTrue(response.contains("data: first"), response)
        XCTAssertTrue(response.contains("data: second"), response)
        let head = try XCTUnwrap(capture.head)
        XCTAssertEqual(head.uri, "/anthropic/v1/messages")
        XCTAssertEqual(head.headers.first(name: "x-api-key"), "sub2api-upstream-key")
        XCTAssertEqual(head.headers.first(name: "authorization"), "Bearer sub2api-upstream-key")
    }

    func testNonAnthropicConnectRemainsAnEncryptedRawTunnel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockRawTunnel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let material = try BridgeCertificateManager.ensureMaterial(directory: root)
        let capture = RequestCapture()
        let upstream = try TestAnthropicUpstream(
            material: material,
            capture: capture,
            host: "::1"
        )
        defer { upstream.stop() }
        let route = try AnthropicBridgeRoute(
            baseURL: XCTUnwrap(URL(string: "https://127.0.0.1:\(upstream.port)")),
            apiKey: "unused-for-raw-tunnel",
            verifyUpstreamTLS: false
        )
        let proxy = AnthropicBridgeProxy(
            route: route,
            material: material,
            upstreamProxyResolver: .direct,
            onEvent: { capture.storeEvent($0.detail) },
            onState: { _, _ in }
        )
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "s_client", "-quiet", "-verify_return_error",
            "-proxy", "127.0.0.1:\(proxyPort)",
            "-connect", "[::1]:\(upstream.port)",
            "-servername", "api.anthropic.com",
            "-CAfile", material.certificateURL.path
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let request = "GET /raw-tunnel HTTP/1.1\r\nHost: api.anthropic.com\r\nConnection: close\r\n\r\n"
        input.fileHandleForWriting.write(Data(request.utf8))
        try input.fileHandleForWriting.close()
        let responseData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let response = String(decoding: responseData, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, response)
        XCTAssertTrue(response.contains("HTTP/1.1 200 OK"), response)
        XCTAssertEqual(capture.head?.uri, "/raw-tunnel")
        XCTAssertTrue(capture.events.contains("Encrypted tunnel established"), "\(capture.events)")
        XCTAssertFalse(capture.events.contains("Anthropic TLS bridge established"), "\(capture.events)")
    }

    func testNonAnthropicConnectChainsThroughConfiguredHTTPProxy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockChainedProxy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let material = try BridgeCertificateManager.ensureMaterial(directory: root)
        let capture = RequestCapture()
        let upstream = try TestAnthropicUpstream(material: material, capture: capture)
        defer { upstream.stop() }
        let upstreamProxy = try TestHTTPConnectProxy()
        defer { upstreamProxy.stop() }
        let route = try AnthropicBridgeRoute(
            baseURL: XCTUnwrap(URL(string: "https://127.0.0.1:\(upstream.port)")),
            apiKey: "unused-for-raw-tunnel",
            verifyUpstreamTLS: false
        )
        let resolver = UpstreamProxyResolver(
            environment: ["HTTPS_PROXY": "http://127.0.0.1:\(upstreamProxy.port)"],
            systemSettings: [:]
        )
        let proxy = AnthropicBridgeProxy(
            route: route,
            material: material,
            upstreamProxyResolver: resolver,
            onEvent: { capture.storeEvent($0.detail) },
            onState: { _, _ in }
        )
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "s_client", "-quiet", "-verify_return_error",
            "-proxy", "127.0.0.1:\(proxyPort)",
            "-connect", "127.0.0.1:\(upstream.port)",
            "-servername", "api.anthropic.com",
            "-CAfile", material.certificateURL.path
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(
            "GET /chained HTTP/1.1\r\nHost: api.anthropic.com\r\nConnection: close\r\n\r\n".utf8
        ))
        try input.fileHandleForWriting.close()
        let responseData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let response = String(decoding: responseData, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, response)
        XCTAssertTrue(response.contains("HTTP/1.1 200 OK"), response)
        XCTAssertEqual(upstreamProxy.targets, ["127.0.0.1:\(upstream.port)"])
        XCTAssertEqual(capture.head?.uri, "/chained")
    }

    func testAbsoluteFormHTTPRequestIsForwardedToTheOriginServer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockPlainHTTP-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let material = try BridgeCertificateManager.ensureMaterial(directory: root)
        let capture = RequestCapture()
        let origin = try TestPlainHTTPOrigin(capture: capture)
        defer { origin.stop() }
        let route = try AnthropicBridgeRoute(
            baseURL: XCTUnwrap(URL(string: "https://gateway.example/anthropic")),
            apiKey: "unused-for-plain-http"
        )
        let proxy = AnthropicBridgeProxy(
            route: route,
            material: material,
            upstreamProxyResolver: .direct,
            onEvent: { capture.storeEvent($0.detail) },
            onState: { _, _ in }
        )
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let response = try runCurl([
            "-sS", "-i", "--max-time", "20",
            "-x", "http://127.0.0.1:\(proxyPort)",
            "http://127.0.0.1:\(origin.port)/plain?probe=1"
        ])
        XCTAssertTrue(response.contains("HTTP/1.1 200 OK"), "\(response)\nEvents: \(capture.events)")
        XCTAssertTrue(response.contains("relaydock-plain-origin"), response)
        let head = try XCTUnwrap(capture.head)
        XCTAssertEqual(head.uri, "/plain?probe=1")
        XCTAssertEqual(head.headers.first(name: "host"), "127.0.0.1:\(origin.port)")
        XCTAssertNil(head.headers.first(name: "proxy-connection"))
        XCTAssertTrue(capture.events.contains("Plain HTTP request forwarded"), "\(capture.events)")
    }

    func testAbsoluteFormHTTPRequestChainsThroughConfiguredProxy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockPlainChain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let material = try BridgeCertificateManager.ensureMaterial(directory: root)
        let capture = RequestCapture()
        let upstreamProxy = try TestAbsoluteFormProxy()
        defer { upstreamProxy.stop() }
        let route = try AnthropicBridgeRoute(
            baseURL: XCTUnwrap(URL(string: "https://gateway.example/anthropic")),
            apiKey: "unused-for-plain-http"
        )
        let proxy = AnthropicBridgeProxy(
            route: route,
            material: material,
            upstreamProxyResolver: UpstreamProxyResolver(
                environment: ["HTTP_PROXY": "http://127.0.0.1:\(upstreamProxy.port)"],
                systemSettings: [:]
            ),
            onEvent: { capture.storeEvent($0.detail) },
            onState: { _, _ in }
        )
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let response = try runCurl([
            "-sS", "-i", "--max-time", "20",
            "-x", "http://127.0.0.1:\(proxyPort)",
            "http://example.invalid/chained-plain"
        ])
        XCTAssertTrue(response.contains("HTTP/1.1 200 OK"), "\(response)\nEvents: \(capture.events)")
        XCTAssertEqual(
            upstreamProxy.requestLines,
            ["GET http://example.invalid/chained-plain HTTP/1.1"]
        )
    }

    func testPlainHTTPParserRejectsOriginFormAndNonProxyTargets() {
        XCTAssertNil(PlainHTTPForwardParser.parse(Data(
            "GET /origin-form HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8
        )))
        XCTAssertNil(PlainHTTPForwardParser.parse(Data(
            "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n".utf8
        )))
        XCTAssertNil(PlainHTTPForwardParser.parse(Data(
            "GET https://example.com/secure HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8
        )))
        XCTAssertNil(PlainHTTPForwardParser.parse(Data("GET http://example.com/ HTTP/1.1\r\n".utf8)))
    }

    func testPlainHTTPParserStripsHopByHopFieldsAndPinsTheConnection() throws {
        let parsed = try XCTUnwrap(PlainHTTPForwardParser.parse(Data("""
        POST http://origin.example:8080/submit?a=1 HTTP/1.1\r
        Host: origin.example:8080\r
        Proxy-Connection: keep-alive\r
        Connection: keep-alive\r
        Proxy-Authorization: Basic c2VjcmV0\r
        Content-Length: 2\r
        \r
        {}
        """.utf8)))
        XCTAssertEqual(parsed.host, "origin.example")
        XCTAssertEqual(parsed.port, 8080)
        XCTAssertEqual(parsed.originRequestLine, "POST /submit?a=1 HTTP/1.1")
        XCTAssertEqual(parsed.forwardedHeaderLines, ["Host: origin.example:8080", "Content-Length: 2"])
        let origin = String(decoding: parsed.originFormHeader, as: UTF8.self)
        XCTAssertEqual(origin, """
        POST /submit?a=1 HTTP/1.1\r
        Host: origin.example:8080\r
        Content-Length: 2\r
        Connection: close\r
        \r

        """)
        let chained = String(decoding: parsed.proxyFormHeader(authorization: "Basic dXA6"), as: UTF8.self)
        XCTAssertTrue(chained.hasPrefix("POST http://origin.example:8080/submit?a=1 HTTP/1.1\r\n"), chained)
        XCTAssertTrue(chained.contains("Proxy-Authorization: Basic dXA6\r\n"), chained)
        XCTAssertFalse(chained.contains("Basic c2VjcmV0"), chained)
    }

    /// Drives the real gateway through the bridge exactly as Cursor would.
    /// Requires RELAYDOCK_LIVE_BRIDGE_TEST=1 plus the gateway base URL and key,
    /// because it spends a small amount of the configured plan's quota.
    func testLiveGatewayThroughBridgeWhenRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RELAYDOCK_LIVE_BRIDGE_TEST"] == "1",
              let baseURLValue = environment["RELAYDOCK_LIVE_ANTHROPIC_BASE_URL"],
              let apiKey = environment["RELAYDOCK_LIVE_ANTHROPIC_KEY"],
              let modelID = environment["RELAYDOCK_LIVE_ANTHROPIC_MODEL"] else {
            throw XCTSkip(
                "Set RELAYDOCK_LIVE_BRIDGE_TEST=1 with RELAYDOCK_LIVE_ANTHROPIC_BASE_URL, "
                    + "RELAYDOCK_LIVE_ANTHROPIC_KEY and RELAYDOCK_LIVE_ANTHROPIC_MODEL."
            )
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockLiveBridge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let material = try BridgeCertificateManager.ensureMaterial(directory: root)
        let capture = RequestCapture()
        let route = try AnthropicBridgeRoute(
            baseURL: XCTUnwrap(URL(string: baseURLValue)),
            apiKey: apiKey
        )
        let proxy = AnthropicBridgeProxy(
            route: route,
            material: material,
            upstreamProxyResolver: UpstreamProxyResolver(),
            onEvent: { capture.storeEvent($0.detail) },
            onState: { _, _ in }
        )
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let body = """
        {"model":"\(modelID)","max_tokens":16,"messages":[{"role":"user","content":"Reply with OK"}]}
        """
        let response = try runCurl([
            "-sS", "-i", "--max-time", "60",
            "-x", "http://127.0.0.1:\(proxyPort)",
            "--proxy-insecure",
            "--cacert", material.certificateURL.path,
            "-H", "x-api-key: \(apiKey)",
            "-H", "anthropic-version: 2023-06-01",
            "-H", "content-type: application/json",
            "--data-binary", body,
            "https://api.anthropic.com/v1/messages"
        ])
        XCTAssertTrue(response.contains("HTTP/1.1 200 OK"), "\(response)\nEvents: \(capture.events)")
        XCTAssertTrue(
            capture.events.contains("Anthropic TLS bridge established"),
            "\(capture.events)"
        )
    }

    private func runCurl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        // A developer machine usually exports NO_PROXY for loopback, which would
        // let curl skip the bridge and silently pass this test against the origin.
        process.environment = [:]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedHead: HTTPRequestHead?
    private var storedEvents: [String] = []

    var head: HTTPRequestHead? {
        lock.lock()
        defer { lock.unlock() }
        return storedHead
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    func store(_ head: HTTPRequestHead) {
        lock.lock()
        storedHead = head
        lock.unlock()
    }

    func storeEvent(_ value: String) {
        lock.lock()
        storedEvents.append(value)
        lock.unlock()
    }
}

private final class TestAnthropicUpstream {
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    let port: Int

    init(
        material: BridgeCertificateMaterial,
        capture: RequestCapture,
        host: String = "127.0.0.1"
    ) throws {
        let certificates = try NIOSSLCertificate.fromPEMFile(material.certificateURL.path)
        let privateKey = try NIOSSLPrivateKey(file: material.privateKeyURL.path, format: .pem)
        let context = try NIOSSLContext(configuration: .makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) },
            privateKey: .privateKey(privateKey)
        ))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        do {
            channel = try ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    do {
                        try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                    return channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(TestAnthropicHandler(capture: capture))
                    }
                }
                .bind(host: host, port: 0)
                .wait()
            port = try XCTUnwrap(channel.localAddress?.port)
        } catch {
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    func stop() {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }
}

private final class TestAnthropicHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let capture: RequestCapture

    init(capture: RequestCapture) { self.capture = capture }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            capture.store(head)
        case .body:
            break
        case .end:
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "text/event-stream")
            headers.add(name: "transfer-encoding", value: "chunked")
            headers.add(name: "connection", value: "close")
            context.write(wrapOutboundOut(.head(HTTPResponseHead(
                version: .http1_1, status: .ok, headers: headers
            ))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(
                context.channel.allocator.buffer(string: "data: first\n\n")
            ))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(
                context.channel.allocator.buffer(string: "data: second\n\n")
            ))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                context.close(promise: nil)
            }
        }
    }
}

private final class TestHTTPConnectProxy: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let capture: TestProxyTargetCapture
    let port: Int

    var targets: [String] { capture.targets }

    init() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let capture = TestProxyTargetCapture()
        self.group = group
        self.capture = capture
        do {
            channel = try ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(TestHTTPConnectProxyHandler(
                        onTarget: { target in capture.store(target) }
                    ))
                }
                .bind(host: "127.0.0.1", port: 0)
                .wait()
            port = try XCTUnwrap(channel.localAddress?.port)
        } catch {
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    func stop() {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }
}

private final class TestProxyTargetCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTargets: [String] = []
    var targets: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedTargets
    }
    func store(_ target: String) {
        lock.lock()
        storedTargets.append(target)
        lock.unlock()
    }
}

private final class TestHTTPConnectProxyHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private var pending: ByteBuffer?
    private let onTarget: @Sendable (String) -> Void

    init(onTarget: @escaping @Sendable (String) -> Void) { self.onTarget = onTarget }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        if pending == nil { pending = context.channel.allocator.buffer(capacity: incoming.readableBytes) }
        pending?.writeBuffer(&incoming)
        guard var pending,
              let request = ConnectRequestParser.parse(Data(pending.readableBytesView)) else { return }
        pending.moveReaderIndex(forwardBy: request.headerLength)
        self.pending = nil
        onTarget("\(request.host):\(request.port)")
        ClientBootstrap(group: context.eventLoop)
            .connect(host: request.host, port: Int(request.port))
            .flatMap { outbound in
                context.pipeline.addHandler(TestRawRelayHandler(peer: outbound), position: .after(self)).map { outbound }
            }.flatMap { outbound in
                return outbound.pipeline.addHandler(TestRawRelayHandler(peer: context.channel)).flatMap {
                    context.writeAndFlush(self.wrapOutboundOut(context.channel.allocator.buffer(
                        string: "HTTP/1.1 200 Connection Established\r\n\r\n"
                    ))).map { outbound }
                }
            }.flatMap { outbound in
                context.pipeline.removeHandler(self).map { outbound }
            }.whenComplete { result in
                switch result {
                case let .success(outbound):
                    if pending.readableBytes > 0 { outbound.writeAndFlush(pending, promise: nil) }
                case .failure:
                    context.close(promise: nil)
                }
            }
    }
}

private final class TestRawRelayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private weak var peer: Channel?

    init(peer: Channel) { self.peer = peer }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let peer else { return context.close(promise: nil) }
        peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) { peer?.close(promise: nil) }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer?.close(promise: nil)
        context.close(promise: nil)
    }
}

private final class TestPlainHTTPOrigin {
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    let port: Int

    init(capture: RequestCapture) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        do {
            channel = try ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(TestPlainHTTPOriginHandler(capture: capture))
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .wait()
            port = try XCTUnwrap(channel.localAddress?.port)
        } catch {
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    func stop() {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }
}

private final class TestPlainHTTPOriginHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let capture: RequestCapture

    init(capture: RequestCapture) { self.capture = capture }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            capture.store(head)
        case .body:
            break
        case .end:
            let body = "relaydock-plain-origin"
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "text/plain")
            headers.add(name: "content-length", value: String(body.utf8.count))
            headers.add(name: "connection", value: "close")
            context.write(wrapOutboundOut(.head(HTTPResponseHead(
                version: .http1_1, status: .ok, headers: headers
            ))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(
                context.channel.allocator.buffer(string: body)
            ))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                context.close(promise: nil)
            }
        }
    }
}

/// Stands in for a local corporate proxy that expects absolute-form requests.
private final class TestAbsoluteFormProxy: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let capture: TestProxyTargetCapture
    let port: Int

    var requestLines: [String] { capture.targets }

    init() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let capture = TestProxyTargetCapture()
        self.group = group
        self.capture = capture
        do {
            channel = try ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(TestAbsoluteFormProxyHandler(
                        onRequestLine: { capture.store($0) }
                    ))
                }
                .bind(host: "127.0.0.1", port: 0)
                .wait()
            port = try XCTUnwrap(channel.localAddress?.port)
        } catch {
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    func stop() {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }
}

private final class TestAbsoluteFormProxyHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private var pending = Data()
    private var answered = false
    private let onRequestLine: @Sendable (String) -> Void

    init(onRequestLine: @escaping @Sendable (String) -> Void) { self.onRequestLine = onRequestLine }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !answered else { return }
        pending.append(contentsOf: unwrapInboundIn(data).readableBytesView)
        guard let marker = pending.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: pending[..<marker.upperBound], encoding: .utf8),
              let requestLine = header.components(separatedBy: "\r\n").first else { return }
        answered = true
        onRequestLine(requestLine)
        let body = "relaydock-chained-proxy"
        let response = "HTTP/1.1 200 OK\r\ncontent-length: \(body.utf8.count)\r\nconnection: close\r\n\r\n" + body
        context.writeAndFlush(wrapOutboundOut(
            context.channel.allocator.buffer(string: response)
        )).whenComplete { _ in context.close(promise: nil) }
    }
}
