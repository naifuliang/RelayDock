import Foundation

struct BridgeCertificateMaterial: Equatable {
    let certificateURL: URL
    let privateKeyURL: URL
    let chainCertificateURLs: [URL]
    let nodeTrustAnchorURL: URL?

    init(
        certificateURL: URL,
        privateKeyURL: URL,
        chainCertificateURLs: [URL] = [],
        nodeTrustAnchorURL: URL? = nil
    ) {
        self.certificateURL = certificateURL
        self.privateKeyURL = privateKeyURL
        self.chainCertificateURLs = chainCertificateURLs
        self.nodeTrustAnchorURL = nodeTrustAnchorURL
    }
}

enum BridgeCertificateManager {
    static let hostname = "api.anthropic.com"
    static let commonName = "RelayDock Anthropic Bridge"

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RelayDock/Bridge", isDirectory: true)
    }

    static func ensureMaterial(directory: URL = directory) throws -> BridgeCertificateMaterial {
        let fileManager = FileManager.default
        let certificateURL = directory.appendingPathComponent("api.anthropic.com.pem")
        let privateKeyURL = directory.appendingPathComponent("api.anthropic.com-key.pem")
        let material = BridgeCertificateMaterial(certificateURL: certificateURL, privateKeyURL: privateKeyURL)

        if fileManager.fileExists(atPath: certificateURL.path)
            || fileManager.fileExists(atPath: privateKeyURL.path) {
            guard fileManager.fileExists(atPath: certificateURL.path),
                  fileManager.fileExists(atPath: privateKeyURL.path),
                  try validate(material) else {
                throw BridgeCertificateError.invalidExistingMaterial
            }
            try protect(material, directory: directory)
            return material
        }

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let configURL = directory.appendingPathComponent("certificate.conf")
        let config = """
        [req]
        distinguished_name = subject
        x509_extensions = extensions
        prompt = no

        [subject]
        CN = \(commonName)

        [extensions]
        subjectAltName = DNS:\(hostname)
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth
        subjectKeyIdentifier = hash
        authorityKeyIdentifier = keyid:always
        """
        try Data(config.utf8).write(to: configURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        defer { try? fileManager.removeItem(at: configURL) }

        do {
            _ = try run(
                "/usr/bin/openssl",
                arguments: [
                    "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
                    "-days", "825", "-config", configURL.path,
                    "-keyout", privateKeyURL.path, "-out", certificateURL.path
                ]
            )
            try protect(material, directory: directory)
            guard try validate(material) else { throw BridgeCertificateError.generationFailed }
            return material
        } catch {
            try? fileManager.removeItem(at: certificateURL)
            try? fileManager.removeItem(at: privateKeyURL)
            throw error
        }
    }

    static func validate(_ material: BridgeCertificateMaterial) throws -> Bool {
        guard FileManager.default.fileExists(atPath: material.certificateURL.path),
              FileManager.default.fileExists(atPath: material.privateKeyURL.path) else { return false }
        guard try validateCertificate(material.certificateURL) else { return false }

        let certificatePublicKey = try run(
            "/usr/bin/openssl",
            arguments: ["x509", "-pubkey", "-noout", "-in", material.certificateURL.path]
        ).output
        let privatePublicKey = try run(
            "/usr/bin/openssl",
            arguments: ["pkey", "-pubout", "-in", material.privateKeyURL.path]
        ).output
        return certificatePublicKey == privatePublicKey
    }

    private static func validateCertificate(
        _ certificateURL: URL,
        requireOperationalValidity: Bool = true
    ) throws -> Bool {
        if requireOperationalValidity {
            let check = try run(
                "/usr/bin/openssl",
                arguments: ["x509", "-checkend", "604800", "-noout", "-in", certificateURL.path],
                allowFailure: true
            )
            guard check.status == 0 else { return false }
        }
        let details = try run(
            "/usr/bin/openssl",
            arguments: ["x509", "-noout", "-text", "-in", certificateURL.path]
        ).output
        let dnsNames = certificateDNSNames(from: details)
        guard dnsNames == [hostname],
              details.contains("CA:FALSE"),
              details.contains("TLS Web Server Authentication") else { return false }
        return true
    }

    static func certificateDNSNames(from subjectAlternativeName: String) -> [String] {
        subjectAlternativeName
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .compactMap { component -> String? in
                let value = component.trimmingCharacters(in: .whitespacesAndNewlines)
                guard value.hasPrefix("DNS:") else { return nil }
                return String(value.dropFirst(4))
            }
    }

    static func installTrust(directory: URL = directory) throws -> BridgeCertificateMaterial {
        let material = try ensureMaterial(directory: directory)
        if try isTrusted(material) { return material }
        let keychainPath = try defaultUserKeychainPath()
        _ = try run(
            "/usr/bin/security",
            arguments: trustInstallationArguments(
                certificateURL: material.certificateURL,
                keychainPath: keychainPath
            )
        )
        try requireTrustedAfterInstallation(
            verification: { try isTrusted(material) },
            rollback: { try removeTrust(directory: directory) }
        )
        return material
    }

    static func requireTrustedAfterInstallation(
        verification: () throws -> Bool,
        rollback: () throws -> Void
    ) throws {
        do {
            guard try verification() else {
                throw BridgeCertificateError.trustVerificationFailed
            }
        } catch {
            let verificationError = error
            do {
                try rollback()
            } catch {
                throw BridgeCertificateError.trustInstallationRollbackFailed(
                    verification: verificationError.localizedDescription,
                    rollback: error.localizedDescription
                )
            }
            throw verificationError
        }
    }

    static func trustInstallationArguments(
        certificateURL: URL,
        keychainPath: String
    ) -> [String] {
        [
            "add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-s", hostname,
            "-k", keychainPath, certificateURL.path
        ]
    }

    static func isTrusted(_ material: BridgeCertificateMaterial) throws -> Bool {
        let result = try run(
            "/usr/bin/security",
            arguments: [
                "verify-cert", "-c", material.certificateURL.path,
                "-p", "ssl", "-s", hostname
            ],
            allowFailure: true
        )
        return result.status == 0
    }

    static func removeTrust(directory: URL = directory) throws {
        for _ in 0..<8 {
            var removedTrust = false
            for certificate in try trustRemovalCandidates(directory: directory) {
                let temporaryURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("RelayDock-Bridge-Trust-\(UUID().uuidString).pem")
                try certificate.write(to: temporaryURL, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                guard try validateCertificate(
                    temporaryURL,
                    requireOperationalValidity: false
                ) else { continue }
                let result = try run(
                    "/usr/bin/security",
                    arguments: ["remove-trusted-cert", temporaryURL.path],
                    allowFailure: true
                )
                if result.status == 0 {
                    removedTrust = true
                } else if !isMissingTrustSetting(result.output) {
                    throw BridgeCertificateError.commandFailed(result.output)
                }
            }
            if !removedTrust { return }
        }
        throw BridgeCertificateError.trustRemovalFailed
    }

    static func isMissingTrustSetting(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("specified item could not be found in the keychain")
    }

    static func pemCertificates(from output: String) -> [Data] {
        let beginMarker = "-----BEGIN CERTIFICATE-----"
        let endMarker = "-----END CERTIFICATE-----"
        var certificates: [Data] = []
        var searchStart = output.startIndex
        while let begin = output.range(of: beginMarker, range: searchStart..<output.endIndex),
              let end = output.range(of: endMarker, range: begin.lowerBound..<output.endIndex) {
            let pem = String(output[begin.lowerBound..<end.upperBound]) + "\n"
            certificates.append(Data(pem.utf8))
            searchStart = end.upperBound
        }
        return certificates
    }

    private static func trustRemovalCandidates(directory: URL) throws -> [Data] {
        var candidates: [Data] = []
        let installedCertificateURL = directory.appendingPathComponent("api.anthropic.com.pem")
        if let installed = try? Data(contentsOf: installedCertificateURL) {
            candidates.append(installed)
        }
        let keychainPath = try defaultUserKeychainPath()
        let result = try run(
            "/usr/bin/security",
            arguments: certificateSearchArguments(keychainPath: keychainPath),
            allowFailure: true
        )
        guard result.status == 0 else {
            throw BridgeCertificateError.commandFailed(result.output)
        }
        candidates.append(contentsOf: pemCertificates(from: result.output))
        var seen = Set<Data>()
        return candidates.filter { seen.insert($0).inserted }
    }

    static func certificateSearchArguments(keychainPath: String) -> [String] {
        ["find-certificate", "-a", "-c", commonName, "-p", keychainPath]
    }

    static func keychainPath(fromDefaultKeychainOutput output: String) -> String? {
        var path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("\"") && path.hasSuffix("\"") && path.count >= 2 {
            path.removeFirst()
            path.removeLast()
        }
        guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r") else {
            return nil
        }
        return path
    }

    private static func defaultUserKeychainPath() throws -> String {
        let result = try run(
            "/usr/bin/security",
            arguments: ["default-keychain", "-d", "user"]
        )
        guard let path = keychainPath(fromDefaultKeychainOutput: result.output) else {
            throw BridgeCertificateError.defaultKeychainUnavailable
        }
        return path
    }

    static func removeAll(directory: URL = directory) throws {
        try removeTrust(directory: directory)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private static func protect(_ material: BridgeCertificateMaterial, directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: material.privateKeyURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: material.certificateURL.path)
    }

    @discardableResult
    private static func run(
        _ executable: String,
        arguments: [String],
        allowFailure: Bool = false
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: outputData, as: UTF8.self)
        if !allowFailure, process.terminationStatus != 0 {
            throw BridgeCertificateError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (process.terminationStatus, output)
    }
}

enum BridgeCertificateError: LocalizedError {
    case invalidExistingMaterial
    case generationFailed
    case trustVerificationFailed
    case trustRemovalFailed
    case defaultKeychainUnavailable
    case trustInstallationRollbackFailed(verification: String, rollback: String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidExistingMaterial:
            return "现有 Anthropic Bridge 证书材料不完整或不再有效；请先一键卸载后重新安装。"
        case .generationFailed:
            return "无法生成限定于 api.anthropic.com 的 Bridge 证书。"
        case .trustVerificationFailed:
            return "证书授权完成后未能通过 api.anthropic.com SSL 信任验证。"
        case .trustRemovalFailed:
            return "系统仍信任 Anthropic Bridge 证书，RelayDock 已保留证书材料以便重试卸载。"
        case .defaultKeychainUnavailable:
            return "无法确定当前用户的默认登录 Keychain；证书信任设置未更改。"
        case let .trustInstallationRollbackFailed(verification, rollback):
            return "证书信任验证失败，且自动撤销未完成：\(verification)；撤销错误：\(rollback)"
        case let .commandFailed(message):
            return message.isEmpty ? "证书系统命令执行失败。" : "证书系统命令失败：\(message)"
        }
    }
}
