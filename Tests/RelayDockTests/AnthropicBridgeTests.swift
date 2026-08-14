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
