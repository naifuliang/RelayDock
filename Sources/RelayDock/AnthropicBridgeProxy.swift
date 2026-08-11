import Foundation
import NIO
import NIOHTTP1
@preconcurrency import NIOSSL

struct AnthropicBridgeRoute: Equatable {
    let baseURL: URL
    let apiKey: String
    let verifyUpstreamTLS: Bool

    init(baseURL: URL, apiKey: String, verifyUpstreamTLS: Bool = true) throws {
        guard baseURL.scheme?.lowercased() == "https",
              baseURL.host != nil,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AnthropicBridgeError.invalidRoute
        }
        self.baseURL = baseURL
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.verifyUpstreamTLS = verifyUpstreamTLS
    }
}

final class AnthropicBridgeProxy: @unchecked Sendable {
    typealias EventHandler = @Sendable (ProxyEvent) -> Void
    typealias StateHandler = @Sendable (Bool, UInt16?) -> Void

    private let route: AnthropicBridgeRoute
    private let material: BridgeCertificateMaterial
    private let onEvent: EventHandler
    private let onState: StateHandler
    private let lock = NSLock()
    private var group: MultiThreadedEventLoopGroup?
    private var serverChannel: Channel?
    private var listeningPort: UInt16?

    init(
        route: AnthropicBridgeRoute,
        material: BridgeCertificateMaterial,
        onEvent: @escaping EventHandler,
        onState: @escaping StateHandler
    ) {
        self.route = route
        self.material = material
        self.onEvent = onEvent
        self.onState = onState
    }

    func start() throws -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        if serverChannel != nil, let listeningPort { return listeningPort }

        var certificates = try NIOSSLCertificate.fromPEMFile(material.certificateURL.path)
        for chainURL in material.chainCertificateURLs {
            certificates.append(contentsOf: try NIOSSLCertificate.fromPEMFile(chainURL.path))
        }
        let privateKey = try NIOSSLPrivateKey(file: material.privateKeyURL.path, format: .pem)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) },
            privateKey: .privateKey(privateKey)
        )
        configuration.applicationProtocols = ["http/1.1"]
        configuration.minimumTLSVersion = .tlsv12
        let serverTLSContext = try NIOSSLContext(configuration: configuration)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group

        do {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 128)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
                .childChannelInitializer { [route, onEvent] channel in
                    channel.pipeline.addHandler(BridgeConnectHandler(
                        serverTLSContext: serverTLSContext,
                        route: route,
                        onEvent: onEvent
                    ))
                }
            let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
            guard let port = channel.localAddress?.port, let bridgePort = UInt16(exactly: port) else {
                try channel.close().wait()
                throw AnthropicBridgeError.bindFailed
            }
            serverChannel = channel
            listeningPort = bridgePort
            onState(true, bridgePort)
            return bridgePort
        } catch {
            try? group.syncShutdownGracefully()
            self.group = nil
            throw error
        }
    }

    func stop() {
        lock.lock()
        let channel = serverChannel
        let group = self.group
        serverChannel = nil
        listeningPort = nil
        self.group = nil
        lock.unlock()

        try? channel?.close().wait()
        try? group?.syncShutdownGracefully()
        onState(false, nil)
    }

    deinit { stop() }
}

enum AnthropicBridgeRequestRewriter {
    static func upstreamURI(incomingURI: String, baseURL: URL) -> String {
        let incoming = URLComponents(string: incomingURI)
        var incomingPath = incoming?.path ?? incomingURI
        if !incomingPath.hasPrefix("/") { incomingPath = "/" + incomingPath }
        let basePath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let lastBaseComponent = basePath.split(separator: "/").last.map(String.init) ?? ""
        let baseIsVersioned = lastBaseComponent.first?.lowercased() == "v"
            && Int(lastBaseComponent.dropFirst()) != nil
        if baseIsVersioned, incomingPath == "/v1" || incomingPath.hasPrefix("/v1/") {
            incomingPath.removeFirst(3)
            if incomingPath.isEmpty { incomingPath = "/" }
        }
        let joinedPath = "/" + [basePath, incomingPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        let query = incoming?.percentEncodedQuery.map { "?" + $0 } ?? ""
        return joinedPath + query
    }

    static func upstreamHead(
        _ head: HTTPRequestHead,
        route: AnthropicBridgeRoute
    ) -> HTTPRequestHead {
        var headers = head.headers
        let wasChunked = headers["transfer-encoding"].contains { value in
            value.lowercased().split(separator: ",").contains {
                $0.trimmingCharacters(in: .whitespaces) == "chunked"
            }
        }
        hopByHopHeaderNames(in: headers).union(["host", "x-api-key", "authorization"]).forEach {
            headers.remove(name: $0)
        }
        if wasChunked { headers.replaceOrAdd(name: "transfer-encoding", value: "chunked") }
        let port = route.baseURL.port ?? 443
        let host = route.baseURL.host ?? ""
        headers.replaceOrAdd(name: "host", value: port == 443 ? host : "\(host):\(port)")
        headers.replaceOrAdd(name: "x-api-key", value: route.apiKey)
        if EndpointValidator.isThirdPartyAnthropicGateway(route.baseURL) {
            headers.replaceOrAdd(name: "authorization", value: "Bearer \(route.apiKey)")
        }
        if !headers.contains(name: "anthropic-version") {
            headers.add(name: "anthropic-version", value: "2023-06-01")
        }
        headers.replaceOrAdd(name: "connection", value: "close")
        return HTTPRequestHead(
            version: .http1_1,
            method: head.method,
            uri: upstreamURI(incomingURI: head.uri, baseURL: route.baseURL),
            headers: headers
        )
    }

    static func hopByHopHeaderNames(in headers: HTTPHeaders) -> Set<String> {
        var names: Set<String> = [
            "connection", "proxy-connection", "keep-alive", "proxy-authenticate",
            "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade"
        ]
        for value in headers["connection"] {
            for token in value.split(separator: ",") {
                let name = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !name.isEmpty { names.insert(name) }
            }
        }
        return names
    }
}

enum AnthropicBridgeClientAuthentication {
    static func isAuthorized(_ head: HTTPRequestHead, expectedAPIKey: String) -> Bool {
        guard let suppliedAPIKey = head.headers.first(name: "x-api-key") else { return false }
        return constantTimeEqual(
            Array(suppliedAPIKey.utf8),
            Array(expectedAPIKey.utf8)
        )
    }

    private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        var difference = UInt64(lhs.count ^ rhs.count)
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            difference |= UInt64(left ^ right)
        }
        return difference == 0
    }
}

enum AnthropicBridgeRequestValidator {
    private static let allowedPaths: Set<String> = [
        "/v1/messages",
        "/v1/messages/count_tokens"
    ]

    static func isAllowed(_ head: HTTPRequestHead) -> Bool {
        guard head.method == .POST,
              head.uri.first == "/",
              !head.uri.contains("#") else { return false }
        let path = String(head.uri.split(
            separator: "?",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )[0])
        return allowedPaths.contains(path)
    }
}

private final class BridgeConnectHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private static let maximumHeaderBytes = 16 * 1024
    private static let maximumNegotiatingBytes = 256 * 1024
    private let serverTLSContext: NIOSSLContext
    private let route: AnthropicBridgeRoute
    private let onEvent: AnthropicBridgeProxy.EventHandler
    private var pending: ByteBuffer?
    private var negotiatingBytes: ByteBuffer?
    private var negotiating = false

    init(
        serverTLSContext: NIOSSLContext,
        route: AnthropicBridgeRoute,
        onEvent: @escaping AnthropicBridgeProxy.EventHandler
    ) {
        self.serverTLSContext = serverTLSContext
        self.route = route
        self.onEvent = onEvent
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        if negotiating {
            if negotiatingBytes == nil {
                negotiatingBytes = context.channel.allocator.buffer(capacity: incoming.readableBytes)
            }
            negotiatingBytes?.writeBuffer(&incoming)
            if negotiatingBytes?.readableBytes ?? 0 > Self.maximumNegotiatingBytes {
                context.close(promise: nil)
            }
            return
        }
        if pending == nil { pending = context.channel.allocator.buffer(capacity: incoming.readableBytes) }
        pending?.writeBuffer(&incoming)
        guard let pending else { return }
        if pending.readableBytes > Self.maximumHeaderBytes {
            reject(context: context, status: "431 Request Header Fields Too Large", detail: "CONNECT header too large")
            return
        }
        let requestData = Data(pending.readableBytesView)
        guard requestData.range(of: Data("\r\n\r\n".utf8)) != nil else { return }
        guard let request = ConnectRequestParser.parse(requestData) else {
            reject(context: context, status: "400 Bad Request", detail: "Only CONNECT is accepted")
            return
        }
        negotiating = true
        var leftover = pending
        leftover.moveReaderIndex(forwardBy: request.headerLength)
        self.pending = nil

        if request.host == BridgeCertificateManager.hostname, request.port == 443 {
            establishAnthropicBridge(context: context, leftover: leftover)
        } else {
            establishTunnel(context: context, request: request, leftover: leftover)
        }
    }

    private func establishAnthropicBridge(context: ChannelHandlerContext, leftover: ByteBuffer) {
        let response = context.channel.allocator.buffer(string: "HTTP/1.1 200 Connection Established\r\nProxy-Agent: RelayDock-Bridge\r\n\r\n")
        context.writeAndFlush(wrapOutboundOut(response)).flatMap { () -> EventLoopFuture<Void> in
            do {
                try context.pipeline.syncOperations.addHandler(
                    NIOSSLServerHandler(context: self.serverTLSContext),
                    position: .after(self)
                )
            } catch {
                return context.eventLoop.makeFailedFuture(error)
            }
            return context.pipeline.configureHTTPServerPipeline().flatMap {
                context.pipeline.addHandler(AnthropicHTTPBridgeHandler(
                    route: self.route,
                    onEvent: self.onEvent
                ))
            }.flatMap {
                context.pipeline.removeHandler(self)
            }
        }.whenComplete { result in
            switch result {
            case .success:
                self.onEvent(ProxyEvent(
                    timestamp: Date(), host: BridgeCertificateManager.hostname, port: 443,
                    kind: .connected, detail: "Anthropic TLS bridge established"
                ))
                var replay = leftover
                if var negotiatingBytes = self.negotiatingBytes {
                    replay.writeBuffer(&negotiatingBytes)
                    self.negotiatingBytes = nil
                }
                if replay.readableBytes > 0 {
                    context.channel.pipeline.fireChannelRead(replay)
                }
            case let .failure(error):
                self.onEvent(ProxyEvent(
                    timestamp: Date(), host: BridgeCertificateManager.hostname, port: 443,
                    kind: .failed, detail: error.localizedDescription
                ))
                context.close(promise: nil)
            }
        }
    }

    private func establishTunnel(
        context: ChannelHandlerContext,
        request: ConnectRequestParser.Request,
        leftover: ByteBuffer
    ) {
        let bootstrap = ClientBootstrap(group: context.eventLoop)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        bootstrap.connect(host: request.host, port: Int(request.port)).flatMap { outbound in
            outbound.pipeline.addHandler(RawRelayHandler(peer: context.channel)).map { outbound }
        }.flatMap { outbound in
            context.pipeline.addHandler(RawRelayHandler(peer: outbound), position: .after(self)).flatMap {
                let response = context.channel.allocator.buffer(
                    string: "HTTP/1.1 200 Connection Established\r\nProxy-Agent: RelayDock\r\n\r\n"
                )
                return context.writeAndFlush(self.wrapOutboundOut(response)).map { outbound }
            }
        }.flatMap { outbound in
            context.pipeline.removeHandler(self).map { outbound }
        }.whenComplete { result in
            switch result {
            case let .success(outbound):
                self.onEvent(ProxyEvent(
                    timestamp: Date(), host: request.host, port: request.port,
                    kind: .tunneled, detail: "Encrypted tunnel established"
                ))
                var replay = leftover
                if var negotiatingBytes = self.negotiatingBytes {
                    replay.writeBuffer(&negotiatingBytes)
                    self.negotiatingBytes = nil
                }
                if replay.readableBytes > 0 { outbound.writeAndFlush(replay, promise: nil) }
            case let .failure(error):
                self.onEvent(ProxyEvent(
                    timestamp: Date(), host: request.host, port: request.port,
                    kind: .failed, detail: error.localizedDescription
                ))
                context.close(promise: nil)
            }
        }
    }

    private func reject(context: ChannelHandlerContext, status: String, detail: String) {
        negotiating = true
        let response = context.channel.allocator.buffer(string: "HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
        context.writeAndFlush(wrapOutboundOut(response)).whenComplete { _ in context.close(promise: nil) }
        onEvent(ProxyEvent(timestamp: Date(), host: "local-client", port: 0, kind: .failed, detail: detail))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

private final class RawRelayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private weak var peer: Channel?

    init(peer: Channel) { self.peer = peer }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let peer, peer.isActive else {
            context.close(promise: nil)
            return
        }
        let buffer = unwrapInboundIn(data)
        context.channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
            peer.writeAndFlush(buffer)
        }.flatMap {
            context.channel.setOption(ChannelOptions.autoRead, value: true)
        }.whenComplete { result in
            switch result {
            case .success: context.read()
            case .failure:
                peer.close(promise: nil)
                context.close(promise: nil)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer?.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer?.close(promise: nil)
        context.close(promise: nil)
    }
}

private final class AnthropicHTTPBridgeHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private static let maximumBufferedBodyBytes = 16 * 1024 * 1024
    private let route: AnthropicBridgeRoute
    private let onEvent: AnthropicBridgeProxy.EventHandler
    private var upstream: Channel?
    private var pendingParts: [HTTPClientRequestPart] = []
    private var pendingBodyBytes = 0
    private var connecting = false

    init(
        route: AnthropicBridgeRoute,
        onEvent: @escaping AnthropicBridgeProxy.EventHandler
    ) {
        self.route = route
        self.onEvent = onEvent
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case let .head(head):
            guard !connecting, upstream == nil else {
                fail(context: context, status: .badRequest, detail: "Pipelined requests are not supported")
                return
            }
            guard AnthropicBridgeRequestValidator.isAllowed(head) else {
                fail(
                    context: context,
                    status: .notFound,
                    detail: "Local client requested an unsupported Anthropic method or path"
                )
                return
            }
            guard AnthropicBridgeClientAuthentication.isAuthorized(
                head,
                expectedAPIKey: route.apiKey
            ) else {
                fail(
                    context: context,
                    status: .unauthorized,
                    detail: "Local client did not present the selected Anthropic endpoint key"
                )
                return
            }
            connecting = true
            enqueue(.head(AnthropicBridgeRequestRewriter.upstreamHead(head, route: route)), context: context)
            connectUpstream(downstream: context.channel)
        case let .body(buffer):
            pendingBodyBytes += buffer.readableBytes
            guard pendingBodyBytes <= Self.maximumBufferedBodyBytes else {
                fail(context: context, status: .payloadTooLarge, detail: "Request body exceeded 16 MiB")
                return
            }
            enqueue(.body(.byteBuffer(buffer)), context: context)
        case let .end(trailers):
            enqueue(.end(trailers), context: context)
        }
    }

    private func connectUpstream(downstream: Channel) {
        guard let host = route.baseURL.host else { return }
        let port = route.baseURL.port ?? 443
        do {
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.certificateVerification = route.verifyUpstreamTLS ? .fullVerification : .none
            configuration.applicationProtocols = ["http/1.1"]
            configuration.minimumTLSVersion = .tlsv12
            let sslContext = try NIOSSLContext(configuration: configuration)
            // Keep connect completion and all handler state on the downstream
            // channel's event loop. The bridge owns mutable request buffers and
            // must never touch them from a second NIO loop.
            let bootstrap = ClientBootstrap(group: downstream.eventLoop)
                .channelInitializer { channel in
                    do {
                        try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(
                            context: sslContext,
                            serverHostname: self.route.verifyUpstreamTLS ? host : nil
                        ))
                        return channel.pipeline.addHTTPClientHandlers().flatMap {
                            channel.pipeline.addHandler(UpstreamResponseRelay(
                                downstream: downstream,
                                onEvent: self.onEvent
                            ))
                        }
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
            bootstrap.connect(host: host, port: port).whenComplete { result in
                switch result {
                case let .success(channel):
                    self.upstream = channel
                    self.flushPending(to: channel)
                case let .failure(error):
                    self.fail(
                        channel: downstream,
                        status: .badGateway,
                        detail: "Anthropic upstream connection failed: \(String(reflecting: error))"
                    )
                }
            }
        } catch {
            fail(channel: downstream, status: .badGateway, detail: error.localizedDescription)
        }
    }

    private func enqueue(_ part: HTTPClientRequestPart, context: ChannelHandlerContext) {
        if let upstream, upstream.isActive {
            context.channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
                upstream.writeAndFlush(part)
            }.flatMap {
                context.channel.setOption(ChannelOptions.autoRead, value: true)
            }.whenComplete { result in
                switch result {
                case .success: context.read()
                case let .failure(error):
                    self.fail(context: context, status: .badGateway, detail: error.localizedDescription)
                }
            }
        } else {
            pendingParts.append(part)
        }
    }

    private func flushPending(to channel: Channel) {
        for part in pendingParts { channel.write(part, promise: nil) }
        pendingParts.removeAll(keepingCapacity: false)
        channel.flush()
    }

    private func fail(context: ChannelHandlerContext, status: HTTPResponseStatus, detail: String) {
        fail(channel: context.channel, status: status, detail: detail)
    }

    private func fail(channel: Channel, status: HTTPResponseStatus, detail: String) {
        pendingParts.removeAll()
        upstream?.close(promise: nil)
        let bodyText = "RelayDock Bridge: \(status.reasonPhrase)"
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "text/plain; charset=utf-8")
        headers.add(name: "content-length", value: String(bodyText.utf8.count))
        headers.add(name: "connection", value: "close")
        channel.write(HTTPServerResponsePart.head(HTTPResponseHead(
            version: .http1_1, status: status, headers: headers
        )), promise: nil)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(channel.allocator.buffer(string: bodyText))), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
        onEvent(ProxyEvent(
            timestamp: Date(), host: BridgeCertificateManager.hostname, port: 443,
            kind: .failed, detail: detail
        ))
    }

    func channelInactive(context: ChannelHandlerContext) {
        upstream?.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        upstream?.close(promise: nil)
        context.close(promise: nil)
    }
}

private final class UpstreamResponseRelay: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    private weak var downstream: Channel?
    private let onEvent: AnthropicBridgeProxy.EventHandler

    init(downstream: Channel, onEvent: @escaping AnthropicBridgeProxy.EventHandler) {
        self.downstream = downstream
        self.onEvent = onEvent
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let downstream, downstream.isActive else {
            context.close(promise: nil)
            return
        }
        let part: HTTPServerResponsePart
        let shouldClose: Bool
        switch unwrapInboundIn(data) {
        case var .head(head):
            let wasChunked = head.headers["transfer-encoding"].contains { value in
                value.lowercased().split(separator: ",").contains {
                    $0.trimmingCharacters(in: .whitespaces) == "chunked"
                }
            }
            AnthropicBridgeRequestRewriter.hopByHopHeaderNames(in: head.headers).forEach {
                head.headers.remove(name: $0)
            }
            if wasChunked { head.headers.replaceOrAdd(name: "transfer-encoding", value: "chunked") }
            head.headers.replaceOrAdd(name: "connection", value: "close")
            part = .head(head)
            shouldClose = false
        case let .body(buffer):
            part = .body(.byteBuffer(buffer))
            shouldClose = false
        case let .end(trailers):
            part = .end(trailers)
            shouldClose = true
            onEvent(ProxyEvent(
                timestamp: Date(), host: BridgeCertificateManager.hostname, port: 443,
                kind: .tunneled, detail: "Anthropic response streamed through Sub2API"
            ))
        }
        context.channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
            downstream.writeAndFlush(part)
        }.flatMap {
            context.channel.setOption(ChannelOptions.autoRead, value: true)
        }.whenComplete { result in
            guard case .success = result else {
                downstream.close(promise: nil)
                context.close(promise: nil)
                return
            }
            if shouldClose {
                downstream.close(promise: nil)
                context.close(promise: nil)
            } else {
                context.read()
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        downstream?.close(promise: nil)
        context.close(promise: nil)
    }
}

enum AnthropicBridgeError: LocalizedError {
    case invalidRoute
    case bindFailed

    var errorDescription: String? {
        switch self {
        case .invalidRoute: return "Anthropic Bridge 需要有效的 HTTPS Endpoint 和 API Key。"
        case .bindFailed: return "Anthropic Bridge 无法绑定本地回环端口。"
        }
    }
}
