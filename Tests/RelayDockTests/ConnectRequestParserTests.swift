import XCTest
@testable import RelayDock

final class ConnectRequestParserTests: XCTestCase {
    func testParsesHostAndPort() {
        let data = Data("CONNECT api.anthropic.com:443 HTTP/1.1\r\nHost: api.anthropic.com:443\r\n\r\n".utf8)
        let request = ConnectRequestParser.parse(data)
        XCTAssertEqual(request?.host, "api.anthropic.com")
        XCTAssertEqual(request?.port, 443)
        XCTAssertEqual(request?.headerLength, data.count)
    }

    func testParsesIPv6Authority() {
        let data = Data("CONNECT [::1]:8443 HTTP/1.1\r\n\r\n".utf8)
        let request = ConnectRequestParser.parse(data)
        XCTAssertEqual(request?.host, "::1")
        XCTAssertEqual(request?.port, 8443)
    }

    func testWaitsForCompleteHeader() {
        let data = Data("CONNECT api.anthropic.com:443 HTTP/1.1\r\n".utf8)
        XCTAssertNil(ConnectRequestParser.parse(data))
    }

    func testRejectsPlainHTTP() {
        let data = Data("GET http://example.com/ HTTP/1.1\r\n\r\n".utf8)
        XCTAssertNil(ConnectRequestParser.parse(data))
        XCTAssertTrue(ConnectRequestParser.hasCompleteHeader(data))
    }

    func testRejectsInvalidPort() {
        let data = Data("CONNECT api.anthropic.com:notaport HTTP/1.1\r\n\r\n".utf8)
        XCTAssertNil(ConnectRequestParser.parse(data))
    }

    func testEndpointRequiresHTTPSExceptLoopback() {
        XCTAssertNotNil(EndpointValidator.normalizedURL(from: "https://gateway.example.com"))
        XCTAssertNil(EndpointValidator.normalizedURL(from: "http://gateway.example.com"))
        XCTAssertNotNil(EndpointValidator.normalizedURL(from: "http://127.0.0.1:8080"))
        XCTAssertNotNil(EndpointValidator.normalizedURL(from: "http://localhost:8080"))
    }
}
