import XCTest
@testable import RelayDock

final class CursorLauncherTests: XCTestCase {
    func testProxyEnvironmentConfiguresChromiumSiblingNodeTraffic() {
        let environment = CursorLauncher.proxyEnvironment(
            port: 64591,
            nodeTrustAnchorURL: URL(fileURLWithPath: "/private/node-issuer.pem"),
            inheriting: ["PRESERVED": "yes", "HTTPS_PROXY": "https://old.invalid"]
        )

        XCTAssertEqual(environment["PRESERVED"], "yes")
        XCTAssertEqual(environment["HTTP_PROXY"], "http://127.0.0.1:64591")
        XCTAssertEqual(environment["HTTPS_PROXY"], "http://127.0.0.1:64591")
        XCTAssertEqual(environment["http_proxy"], "http://127.0.0.1:64591")
        XCTAssertEqual(environment["https_proxy"], "http://127.0.0.1:64591")
        XCTAssertEqual(environment["NO_PROXY"], "localhost,127.0.0.1,::1")
        XCTAssertEqual(environment["no_proxy"], "localhost,127.0.0.1,::1")
        XCTAssertEqual(environment["NODE_USE_ENV_PROXY"], "1")
        XCTAssertEqual(environment["NODE_USE_SYSTEM_CA"], "1")
        XCTAssertEqual(environment["NODE_EXTRA_CA_CERTS"], "/private/node-issuer.pem")
        XCTAssertNil(environment["NODE_TLS_REJECT_UNAUTHORIZED"])
    }

    // Cursor's *runtime* behaviour is covered by
    // AnthropicBridgeTests.testCursorBundledNodeFetchUsesRelayDockProxy, which runs
    // the installed Cursor's bundled Node and proves a real fetch() reaches the
    // Bridge through these variables and the process-scoped issuer. An earlier
    // `ps`-scraping test that watched Electron's helper processes was removed:
    // Cursor reparents its tree and `ps e` cannot reliably render a large
    // inherited environment, so it failed for reasons unrelated to RelayDock.
}
