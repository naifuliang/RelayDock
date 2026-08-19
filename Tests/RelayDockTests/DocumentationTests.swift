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
        XCTAssertTrue(guide.contains("Never display, paste into chat, log, or save the complete API key"))
        XCTAssertTrue(guide.contains("/v1/chat/completions"))

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
