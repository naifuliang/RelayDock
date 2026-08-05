import CryptoKit
import XCTest
@testable import RelayDock

final class UpdateTests: XCTestCase {
    func testSemanticVersionComparison() {
        XCTAssertTrue(VersionComparator.isNewer("0.2.0", than: "0.1.9"))
        XCTAssertTrue(VersionComparator.isNewer("v1.0.1", than: "1.0.0"))
        XCTAssertFalse(VersionComparator.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(VersionComparator.isNewer("0.9.9", than: "1.0.0"))
    }

    func testDecodesGitHubReleaseAssetsAndDigest() throws {
        let json = #"""
        {
          "tag_name": "v0.2.0",
          "html_url": "https://github.com/naifuliang/RelayDock/releases/tag/v0.2.0",
          "draft": false,
          "prerelease": false,
          "assets": [{
            "name": "RelayDock-0.2.0.dmg",
            "browser_download_url": "https://example.com/RelayDock-0.2.0.dmg",
            "digest": "sha256:abc123"
          }]
        }
        """#.data(using: .utf8)!
        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        XCTAssertEqual(release.version, "0.2.0")
        XCTAssertEqual(release.assets.first?.name, "RelayDock-0.2.0.dmg")
        XCTAssertEqual(release.assets.first?.digest, "sha256:abc123")
    }

    func testDownloadFailsClosedWhenDigestIsMissing() async {
        let release = GitHubRelease(
            tagName: "v0.2.0",
            htmlURL: URL(string: "https://example.com/release")!,
            draft: false,
            prerelease: false,
            assets: [.init(
                name: "RelayDock-0.2.0.dmg",
                browserDownloadURL: URL(string: "https://example.com/RelayDock-0.2.0.dmg")!,
                digest: nil
            )]
        )
        do {
            _ = try await GitHubUpdater.downloadDMG(from: release)
            XCTFail("Expected a missing digest failure")
        } catch let error as UpdateError {
            XCTAssertEqual(error.errorDescription, UpdateError.missingDigest.errorDescription)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDownloadRequiresVersionedRelayDockDMG() async {
        let release = GitHubRelease(
            tagName: "v0.2.0",
            htmlURL: URL(string: "https://example.com/release")!,
            draft: false,
            prerelease: false,
            assets: [.init(
                name: "SomethingElse.dmg",
                browserDownloadURL: URL(string: "https://example.com/SomethingElse.dmg")!,
                digest: "sha256:\(String(repeating: "0", count: 64))"
            )]
        )
        do {
            _ = try await GitHubUpdater.downloadDMG(from: release)
            XCTFail("Expected a missing DMG failure")
        } catch let error as UpdateError {
            XCTAssertEqual(error.errorDescription, UpdateError.missingDMG.errorDescription)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDownloadRejectsChecksumMismatch() async throws {
        MockDownloadProtocol.data = Data("not-the-expected-payload".utf8)
        let session = makeMockSession()
        let release = makeRelease(digest: "sha256:\(String(repeating: "0", count: 64))")
        do {
            _ = try await GitHubUpdater.downloadDMG(from: release, session: session)
            XCTFail("Expected checksum mismatch")
        } catch let error as UpdateError {
            XCTAssertEqual(error.errorDescription, UpdateError.checksumMismatch.errorDescription)
        }
    }

    func testDownloadVerifiesDigestAndAvoidsFilenameCollision() async throws {
        let payload = Data("verified-dmg-payload".utf8)
        MockDownloadProtocol.data = payload
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let release = makeRelease(digest: "sha256:\(digest)")
        let downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockUpdateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: downloads) }
        try Data("existing".utf8).write(to: downloads.appendingPathComponent("RelayDock-0.2.0.dmg"))

        let destination = try await GitHubUpdater.downloadDMG(
            from: release,
            session: makeMockSession(),
            downloadsDirectory: downloads
        )
        XCTAssertEqual(destination.lastPathComponent, "RelayDock-0.2.0 (2).dmg")
        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    private func makeRelease(digest: String?) -> GitHubRelease {
        GitHubRelease(
            tagName: "v0.2.0",
            htmlURL: URL(string: "https://example.com/release")!,
            draft: false,
            prerelease: false,
            assets: [.init(
                name: "RelayDock-0.2.0.dmg",
                browserDownloadURL: URL(string: "https://example.com/RelayDock-0.2.0.dmg")!,
                digest: digest
            )]
        )
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockDownloadProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MockDownloadProtocol: URLProtocol, @unchecked Sendable {
    static var data = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
