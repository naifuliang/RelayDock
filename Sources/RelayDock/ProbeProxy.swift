import Foundation
import Network

final class ProbeProxy: @unchecked Sendable {
    typealias EventHandler = @Sendable (ProxyEvent) -> Void
    typealias StateHandler = @Sendable (Bool, UInt16?) -> Void

    private let queue = DispatchQueue(label: "app.relaydock.proxy", qos: .userInitiated)
    private var listener: NWListener?
    private var generation: UUID?
    private var sessions: [UUID: ProxySession] = [:]
    private let maximumSessions = 64
    private let onEvent: EventHandler
    private let onState: StateHandler

    init(onEvent: @escaping EventHandler, onState: @escaping StateHandler) {
        self.onEvent = onEvent
        self.onState = onState
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let loopback = IPv4Address("127.0.0.1") else {
            throw ProxyError.loopbackUnavailable
        }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: .any)
        let newListener = try NWListener(using: parameters)
        let token = UUID()

        queue.sync {
            guard self.listener == nil else { return }
            self.listener = newListener
            self.generation = token

            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                guard let self, self.generation == token else { return }
                switch state {
                case .ready:
                    self.onState(true, newListener?.port?.rawValue)
                case .failed(let error):
                    self.onEvent(ProxyEvent(timestamp: Date(), host: "local-proxy", port: 0, kind: .failed, detail: error.localizedDescription))
                    self.stop()
                case .cancelled:
                    self.onState(false, nil)
                default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                guard let self, self.generation == token else {
                    connection.cancel()
                    return
                }
                guard self.sessions.count < self.maximumSessions else {
                    self.onEvent(ProxyEvent(timestamp: Date(), host: "local-client", port: 0, kind: .failed, detail: "Session limit reached"))
                    connection.cancel()
                    return
                }
                let id = UUID()
                let session = ProxySession(id: id, client: connection, queue: self.queue, onEvent: self.onEvent) { [weak self] id in
                    self?.sessions.removeValue(forKey: id)
                }
                self.sessions[id] = session
                session.start()
            }
            newListener.start(queue: self.queue)
        }
    }

    func stop() {
        queue.async { [self] in
            self.generation = nil
            self.listener?.cancel()
            self.listener = nil
            let activeSessions = Array(self.sessions.values)
            self.sessions.removeAll()
            activeSessions.forEach { $0.cancel() }
            self.onState(false, nil)
        }
    }
}

private enum ProxyError: LocalizedError {
    case loopbackUnavailable
    var errorDescription: String? { L10n.t("Could not bind the IPv4 loopback address", zh: "无法绑定 IPv4 loopback 地址") }
}

private final class ProxySession: @unchecked Sendable {
    private let id: UUID
    private let client: NWConnection
    private let queue: DispatchQueue
    private let onEvent: ProbeProxy.EventHandler
    private let onClose: @Sendable (UUID) -> Void
    private var upstream: NWConnection?
    private var handshakeBuffer = Data()
    private var closed = false
    private var handshakeTimeout: DispatchWorkItem?
    private var upstreamTimeout: DispatchWorkItem?

    init(id: UUID, client: NWConnection, queue: DispatchQueue, onEvent: @escaping ProbeProxy.EventHandler, onClose: @escaping @Sendable (UUID) -> Void) {
        self.id = id
        self.client = client
        self.queue = queue
        self.onEvent = onEvent
        self.onClose = onClose
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.cancel() }
        }
        client.start(queue: queue)
        let timeout = DispatchWorkItem { [weak self] in
            self?.fail(host: "unknown", port: 0, message: "Proxy handshake timed out", status: "408 Request Timeout")
        }
        handshakeTimeout = timeout
        queue.asyncAfter(deadline: .now() + 8, execute: timeout)
        receiveHandshake()
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        handshakeTimeout?.cancel()
        upstreamTimeout?.cancel()
        client.cancel()
        upstream?.cancel()
        onClose(id)
    }

    private func receiveHandshake() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.handshakeBuffer.append(data) }
            if let request = ConnectRequestParser.parse(self.handshakeBuffer) {
                self.handshakeTimeout?.cancel()
                self.openTunnel(request)
                return
            }
            if ConnectRequestParser.hasCompleteHeader(self.handshakeBuffer) {
                self.fail(host: "unknown", port: 0, message: "Only HTTP CONNECT is supported", status: "405 Method Not Allowed")
                return
            }
            if self.handshakeBuffer.count >= 64 * 1024 {
                self.fail(host: "unknown", port: 0, message: "Proxy request header is too large", status: "431 Request Header Fields Too Large")
                return
            }
            if complete || error != nil {
                self.cancel()
            } else {
                self.receiveHandshake()
            }
        }
    }

    private func openTunnel(_ request: ConnectRequestParser.Request) {
        onEvent(ProxyEvent(timestamp: Date(), host: request.host, port: request.port, kind: .connected, detail: "CONNECT observed"))
        let connection = NWConnection(host: NWEndpoint.Host(request.host), port: NWEndpoint.Port(rawValue: request.port)!, using: .tcp)
        upstream = connection
        let timeout = DispatchWorkItem { [weak self] in
            self?.fail(host: request.host, port: request.port, message: "Upstream connection timed out", status: "504 Gateway Timeout")
        }
        upstreamTimeout = timeout
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.upstreamTimeout?.cancel()
                self.establish(request)
            case .failed(let error):
                self.upstreamTimeout?.cancel()
                self.fail(host: request.host, port: request.port, message: error.localizedDescription)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func establish(_ request: ConnectRequestParser.Request) {
        guard let upstream else { return }
        let response = Data("HTTP/1.1 200 Connection Established\r\nProxy-Agent: RelayDock\r\n\r\n".utf8)
        client.send(content: response, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.fail(host: request.host, port: request.port, message: error.localizedDescription)
                return
            }
            let remainder = self.handshakeBuffer.dropFirst(request.headerLength)
            self.handshakeBuffer.removeAll(keepingCapacity: false)
            if !remainder.isEmpty {
                upstream.send(content: Data(remainder), completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if let sendError {
                        self.fail(host: request.host, port: request.port, message: sendError.localizedDescription)
                    } else {
                        self.beginPumps(upstream: upstream, request: request)
                    }
                })
            } else {
                self.beginPumps(upstream: upstream, request: request)
            }
        })
    }

    private func beginPumps(upstream: NWConnection, request: ConnectRequestParser.Request) {
        onEvent(ProxyEvent(timestamp: Date(), host: request.host, port: request.port, kind: .tunneled, detail: "Encrypted tunnel established"))
        pump(from: client, to: upstream)
        pump(from: upstream, to: client)
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if sendError == nil && !complete {
                        self.pump(from: source, to: destination)
                    } else {
                        self.cancel()
                    }
                })
            } else if complete || error != nil {
                self.cancel()
            } else {
                self.pump(from: source, to: destination)
            }
        }
    }

    private func fail(host: String, port: UInt16, message: String, status: String = "502 Bad Gateway") {
        guard !closed else { return }
        onEvent(ProxyEvent(timestamp: Date(), host: host, port: port, kind: .failed, detail: message))
        let response = Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        client.send(content: response, completion: .contentProcessed { [weak self] _ in self?.cancel() })
    }
}
