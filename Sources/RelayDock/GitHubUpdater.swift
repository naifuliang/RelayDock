import CryptoKit
import Foundation

enum GitHubUpdater {
    static let releasesAPI = URL(string: "https://api.github.com/repos/naifuliang/RelayDock/releases/latest")!
    static let latestChecksumsURL = URL(string: "https://github.com/naifuliang/RelayDock/releases/latest/download/SHA256SUMS")!

    static func fetchLatestRelease(session: URLSession = .shared) async throws -> GitHubRelease {
        var request = URLRequest(url: releasesAPI)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RelayDock-macOS", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return try JSONDecoder().decode(GitHubRelease.self, from: data)
            }
        } catch {
            // The checksum asset below is served by GitHub Releases and does not
            // consume the unauthenticated REST API quota.
        }
        return try await fetchLatestReleaseFromChecksums(session: session)
    }

    static func releaseFromChecksums(_ data: Data) throws -> GitHubRelease {
        guard let body = String(data: data, encoding: .utf8) else { throw UpdateError.invalidResponse }
        for line in body.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard fields.count >= 2 else { continue }
            let digest = String(fields[0]).lowercased()
            let fileName = String(fields[fields.count - 1])
            guard fileName.hasPrefix("RelayDock-"), fileName.hasSuffix(".dmg"),
                  digest.count == 64, digest.allSatisfy(\.isHexDigit) else { continue }
            let version = String(fileName.dropFirst("RelayDock-".count).dropLast(".dmg".count))
            guard UpdateInstaller.isSafeVersion(version),
                  let htmlURL = URL(string: "https://github.com/naifuliang/RelayDock/releases/tag/v\(version)"),
                  let downloadURL = URL(string: "https://github.com/naifuliang/RelayDock/releases/download/v\(version)/\(fileName)") else {
                throw UpdateError.invalidResponse
            }
            return GitHubRelease(
                tagName: "v\(version)",
                htmlURL: htmlURL,
                draft: false,
                prerelease: false,
                assets: [.init(name: fileName, browserDownloadURL: downloadURL, digest: "sha256:\(digest)")]
            )
        }
        throw UpdateError.invalidResponse
    }

    static func shouldSkipAutomaticCheck(
        lastCheck: Date?,
        lastOutcome: String?,
        lastCheckedAppVersion: String?,
        currentVersion: String,
        now: Date = Date()
    ) -> Bool {
        guard let lastCheck,
              lastOutcome == "upToDate",
              lastCheckedAppVersion == currentVersion else { return false }
        return now.timeIntervalSince(lastCheck) < 24 * 60 * 60
    }

    static func downloadDMG(
        from release: GitHubRelease,
        session: URLSession = .shared,
        downloadsDirectory: URL? = nil
    ) async throws -> URL {
        let expectedAssetName = "RelayDock-\(release.version).dmg"
        guard let asset = release.assets.first(where: { $0.name == expectedAssetName }) else {
            throw UpdateError.missingDMG
        }
        guard let digest = asset.digest else { throw UpdateError.missingDigest }
        guard digest.lowercased().hasPrefix("sha256:") else { throw UpdateError.unsupportedDigest }
        let expected = String(digest.dropFirst("sha256:".count)).lowercased()
        guard expected.count == 64, expected.allSatisfy(\.isHexDigit) else {
            throw UpdateError.unsupportedDigest
        }
        var request = URLRequest(url: asset.browserDownloadURL)
        request.timeoutInterval = 300
        request.setValue("RelayDock-macOS", forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.invalidResponse
        }
        let data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw UpdateError.checksumMismatch }

        let fileManager = FileManager.default
        let downloads = downloadsDirectory
            ?? fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        let destination = availableDestination(
            named: URL(fileURLWithPath: asset.name).lastPathComponent,
            in: downloads,
            fileManager: fileManager
        )
        try fileManager.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private static func availableDestination(named fileName: String, in directory: URL, fileManager: FileManager) -> URL {
        let original = directory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: original.path) else { return original }
        let base = original.deletingPathExtension().lastPathComponent
        let pathExtension = original.pathExtension
        for index in 2...999 {
            let candidate = directory.appendingPathComponent("\(base) (\(index)).\(pathExtension)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(base)-\(UUID().uuidString).\(pathExtension)")
    }

    private static func fetchLatestReleaseFromChecksums(session: URLSession) async throws -> GitHubRelease {
        var request = URLRequest(url: latestChecksumsURL)
        request.timeoutInterval = 20
        request.setValue("RelayDock-macOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.invalidResponse
        }
        return try releaseFromChecksums(data)
    }
}

enum UpdateError: LocalizedError {
    case invalidResponse
    case missingDMG
    case missingDigest
    case unsupportedDigest
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GitHub 更新服务返回了无效响应。"
        case .missingDMG: return "最新 Release 中没有找到 DMG 安装包。"
        case .missingDigest: return "GitHub 尚未提供更新包的 SHA-256 digest，已停止下载。"
        case .unsupportedDigest: return "GitHub 更新包 digest 格式不受支持，已停止下载。"
        case .checksumMismatch: return "下载的更新包未通过 GitHub SHA-256 校验。"
        }
    }
}
