import Foundation
import XCTest
@testable import RelayDock

final class DocumentationTests: XCTestCase {
    func testCodexSetupGuideLinkTargetsVersionControlledDocument() throws {
        XCTAssertEqual(
            RelayDockLinks.codexSub2APISetupGuide.absoluteString,
            "https://github.com/naifuliang/RelayDock/blob/main/docs/CODEX_SUB2API_SETUP.md"
        )

        let guideURL = repositoryRoot.appendingPathComponent("docs/CODEX_SUB2API_SETUP.md")
        let guide = try String(contentsOf: guideURL, encoding: .utf8)
        XCTAssertTrue(guide.contains("Codex Desktop with Computer Use"))
        XCTAssertTrue(guide.contains("Codex CLI"))
        XCTAssertTrue(guide.contains("Do not create, reveal, copy, inspect, test, or otherwise handle an API key"))
        XCTAssertTrue(guide.contains("Stop before opening the key-creation form"))
        XCTAssertTrue(guide.contains("If GET /v1/models"))
        XCTAssertTrue(guide.contains("replace each model ID with the corresponding `rd-*` alias"))

        let readme = try String(
            contentsOf: repositoryRoot.appendingPathComponent("README.md"),
            encoding: .utf8
        )
        XCTAssertTrue(readme.contains("[Codex Desktop Sub2API setup guide](docs/CODEX_SUB2API_SETUP.md)"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
