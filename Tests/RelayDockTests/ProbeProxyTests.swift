import Network
import XCTest
@testable import RelayDock

final class ProbeProxyTests: XCTestCase {
    func testBindsToLoopbackAndObservesConnect() throws {
        let ready = expectation(description: "proxy ready")
        let observed = expectation(description: "CONNECT observed")
        let listeningPort = LockedBox<UInt16?>(nil)

        let proxy = ProbeProxy(
            onEvent: { event in
                if event.kind == .connected && event.host == "127.0.0.1" && event.port == 9 {
                    observed.fulfill()
                }
            },
            onState: { running, port in
                if running {
                    listeningPort.set(port)
                    ready.fulfill()
                }
            }
        )
        try proxy.start()
        wait(for: [ready], timeout: 3)
        let port = try XCTUnwrap(listeningPort.value)

        let queue = DispatchQueue(label: "app.relaydock.tests.client")
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        client.stateUpdateHandler = { state in
            if case .ready = state {
                let request = Data("CONNECT 127.0.0.1:9 HTTP/1.1\r\nHost: 127.0.0.1:9\r\n\r\n".utf8)
                client.send(content: request, completion: .contentProcessed { _ in })
            }
        }
        client.start(queue: queue)

        wait(for: [observed], timeout: 3)
        client.cancel()
        proxy.stop()
    }

    func testRejectsPlainHTTPImmediately() throws {
        let ready = expectation(description: "proxy ready")
        let rejected = expectation(description: "plain HTTP rejected")
        let listeningPort = LockedBox<UInt16?>(nil)

        let proxy = ProbeProxy(
            onEvent: { _ in },
            onState: { running, port in
                if running {
                    listeningPort.set(port)
                    ready.fulfill()
                }
            }
        )
        try proxy.start()
        wait(for: [ready], timeout: 3)
        let port = try XCTUnwrap(listeningPort.value)

        let queue = DispatchQueue(label: "app.relaydock.tests.http-client")
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        client.stateUpdateHandler = { state in
            if case .ready = state {
                client.send(content: Data("GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    if let data, String(decoding: data, as: UTF8.self).contains("405 Method Not Allowed") {
                        rejected.fulfill()
                    }
                }
            }
        }
        client.start(queue: queue)

        wait(for: [rejected], timeout: 3)
        client.cancel()
        proxy.stop()
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}
