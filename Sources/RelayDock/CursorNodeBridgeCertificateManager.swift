import Foundation

/// Creates a process-scoped issuer for Cursor's bundled Node runtime.
///
/// The issuer is never installed in a Keychain and its private key is deleted
/// immediately after the api.anthropic.com leaf is signed. Cursor receives only
/// the public issuer through NODE_EXTRA_CA_CERTS. The existing macOS trust flow
/// remains a hostname/policy-limited leaf trust for Chromium traffic.
enum CursorNodeBridgeCertificateManager {
    static var directory: URL {
        BridgeCertificateManager.directory.appendingPathComponent("Node", isDirectory: true)
    }

    static func ensureMaterial(directory: URL = directory) throws -> BridgeCertificateMaterial {
        let fileManager = FileManager.default
        let leafURL = directory.appendingPathComponent("api.anthropic.com.pem")
        let leafKeyURL = directory.appendingPathComponent("api.anthropic.com-key.pem")
        let issuerURL = directory.appendingPathComponent("node-issuer.pem")
        let issuerKeyURL = directory.appendingPathComponent(".node-issuer-key.pem")
        let requestURL = directory.appendingPathComponent(".api.anthropic.com.csr")
        let serialURL = directory.appendingPathComponent("node-issuer.srl")
        let issuerConfigURL = directory.appendingPathComponent(".issuer.conf")
        let leafConfigURL = directory.appendingPathComponent(".leaf.conf")
        let temporaryURLs = [issuerKeyURL, requestURL, serialURL, issuerConfigURL, leafConfigURL]
        let material = BridgeCertificateMaterial(
            certificateURL: leafURL,
            privateKeyURL: leafKeyURL,
            chainCertificateURLs: [issuerURL],
            nodeTrustAnchorURL: issuerURL
        )

        if fileManager.fileExists(atPath: directory.path) {
            try removeTemporaryFiles(temporaryURLs)
        }

        if fileManager.fileExists(atPath: leafURL.path),
           fileManager.fileExists(atPath: leafKeyURL.path),
           fileManager.fileExists(atPath: issuerURL.path),
           try validate(material) {
            try protect(material, directory: directory)
            return material
        }

        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        defer { temporaryURLs.forEach { try? fileManager.removeItem(at: $0) } }

        let issuerConfig = """
        [req]
        distinguished_name = subject
        x509_extensions = extensions
        prompt = no

        [subject]
        CN = RelayDock Cursor Node Bridge Issuer

        [extensions]
        basicConstraints = critical,CA:TRUE,pathlen:0
        keyUsage = critical,keyCertSign,cRLSign
        nameConstraints = critical,permitted;DNS:\(BridgeCertificateManager.hostname),excluded;DNS:.\(BridgeCertificateManager.hostname)
        subjectKeyIdentifier = hash
        authorityKeyIdentifier = keyid:always
        """
        let leafConfig = """
        [req]
        distinguished_name = subject
        prompt = no

        [subject]
        CN = \(BridgeCertificateManager.commonName) (Cursor Node)

        [extensions]
        subjectAltName = DNS:\(BridgeCertificateManager.hostname)
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth
        subjectKeyIdentifier = hash
        authorityKeyIdentifier = keyid,issuer
        """
        try writeProtected(issuerConfig, to: issuerConfigURL)
        try writeProtected(leafConfig, to: leafConfigURL)

        do {
            try run([
                "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
                "-days", "825", "-config", issuerConfigURL.path,
                "-keyout", issuerKeyURL.path, "-out", issuerURL.path
            ])
            try run([
                "req", "-new", "-newkey", "rsa:2048", "-sha256", "-nodes",
                "-config", leafConfigURL.path,
                "-keyout", leafKeyURL.path, "-out", requestURL.path
            ])
            try run([
                "x509", "-req", "-sha256", "-days", "825",
                "-in", requestURL.path, "-CA", issuerURL.path,
                "-CAkey", issuerKeyURL.path, "-CAcreateserial",
                "-extfile", leafConfigURL.path, "-extensions", "extensions",
                "-out", leafURL.path
            ])
            // The issuer exists only to create this one leaf. Never return usable
            // material while its signing key or other generation state remains.
            try removeTemporaryFiles(temporaryURLs)
            try protect(material, directory: directory)
            guard try validate(material) else { throw BridgeCertificateError.generationFailed }
            return material
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private static func validate(_ material: BridgeCertificateMaterial) throws -> Bool {
        guard let issuerURL = material.nodeTrustAnchorURL else { return false }
        let verify = try run([
            "verify", "-CAfile", issuerURL.path, material.certificateURL.path
        ], allowFailure: true)
        guard verify.status == 0 else { return false }

        let leaf = try run(["x509", "-noout", "-text", "-in", material.certificateURL.path]).output
        let issuer = try run(["x509", "-noout", "-text", "-in", issuerURL.path]).output
        guard BridgeCertificateManager.certificateDNSNames(from: leaf) == [BridgeCertificateManager.hostname],
              leaf.contains("CA:FALSE"), leaf.contains("TLS Web Server Authentication"),
              issuer.contains("CA:TRUE"), issuer.contains("pathlen:0"),
              issuer.contains("X509v3 Name Constraints: critical"),
              issuer.contains("Permitted:"),
              issuer.contains("DNS:\(BridgeCertificateManager.hostname)"),
              issuer.contains("Excluded:"),
              issuer.contains("DNS:.\(BridgeCertificateManager.hostname)") else { return false }

        let certificatePublicKey = try run([
            "x509", "-pubkey", "-noout", "-in", material.certificateURL.path
        ]).output
        let privatePublicKey = try run([
            "pkey", "-pubout", "-in", material.privateKeyURL.path
        ]).output
        return certificatePublicKey == privatePublicKey
    }

    private static func protect(_ material: BridgeCertificateMaterial, directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for url in [material.certificateURL, material.privateKeyURL] + material.chainCertificateURLs {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private static func writeProtected(_ value: String, to url: URL) throws {
        try Data(value.utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func removeTemporaryFiles(_ urls: [URL]) throws {
        let fileManager = FileManager.default
        for url in urls where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        guard !urls.contains(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw BridgeCertificateError.generationFailed
        }
    }

    @discardableResult
    private static func run(
        _ arguments: [String],
        allowFailure: Bool = false
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        if !allowFailure, process.terminationStatus != 0 {
            throw BridgeCertificateError.commandFailed(
                output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return (process.terminationStatus, output)
    }
}
