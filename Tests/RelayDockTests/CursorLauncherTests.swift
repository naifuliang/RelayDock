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

    func testRealCursorElectronServiceInheritsRelayDockEnvironment() throws {
        guard ProcessInfo.processInfo.environment["RELAYDOCK_CURSOR_ENV_INHERITANCE_TEST"] == "1" else {
            throw XCTSkip("Set RELAYDOCK_CURSOR_ENV_INHERITANCE_TEST=1 for the isolated Electron test.")
        }
        guard FileManager.default.isExecutableFile(atPath: CursorLauncher.executableURL.path) else {
            throw XCTSkip("Cursor is not installed in /Applications.")
        }

        let marker = "relaydock-env-\(UUID().uuidString)"
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDock-Cursor-Environment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let process = Process()
        process.executableURL = CursorLauncher.executableURL
        process.arguments = [
            "--user-data-dir=\(dataDirectory.path)",
            "--no-first-run",
            "--disable-gpu",
            "--proxy-server=http://127.0.0.1:9"
        ]
        var environment = CursorLauncher.proxyEnvironment(port: 9)
        environment["RELAYDOCK_ENV_TEST_MARKER"] = marker
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        var observedElectronService = false
        var diagnostics: [String] = []
        for _ in 0..<60 where !observedElectronService {
            Thread.sleep(forTimeInterval: 0.25)
            let processTable = try runProcess(
                "/bin/ps",
                arguments: ["eww", "-axo", "pid=,ppid=,command="]
            )
            for line in processTable.split(separator: "\n") where line.contains(marker) {
                let command = String(line)
                let executableSummary = command
                    .split(separator: " ", maxSplits: 12, omittingEmptySubsequences: true)
                    .prefix(12)
                    .joined(separator: " ")
                diagnostics.append(
                    "node=\(command.contains("node.mojom.NodeService")) helper=\(command.contains("Cursor Helper")) \(executableSummary)"
                )
                if command.contains("Cursor Helper"),
                   command.contains("--type=utility"),
                   command.contains(".mojom.") {
                    observedElectronService = true
                    break
                }
            }
        }
        XCTAssertTrue(
            observedElectronService,
            "Cursor's actual Electron service did not inherit the launch environment. \(diagnostics.suffix(20))"
        )
    }

    private func runProcess(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "CursorLauncherTests", code: Int(process.terminationStatus))
        }
        return String(decoding: data, as: UTF8.self)
    }
}
