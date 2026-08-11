import Foundation
import XCTest
@testable import RelayDock

final class CursorNodeBridgeCertificateManagerTests: XCTestCase {
    func testCreatesProcessScopedChainAndDestroysIssuerPrivateKey() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockNodeMaterial-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let material = try CursorNodeBridgeCertificateManager.ensureMaterial(directory: root)
        let issuer = try XCTUnwrap(material.nodeTrustAnchorURL)
        XCTAssertEqual(material.chainCertificateURLs, [issuer])
        XCTAssertTrue(FileManager.default.fileExists(atPath: material.certificateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: material.privateKeyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: issuer.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".node-issuer-key.pem").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("node-issuer.srl").path
        ))

        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        for url in [material.certificateURL, material.privateKeyURL, issuer] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }

        let second = try CursorNodeBridgeCertificateManager.ensureMaterial(directory: root)
        XCTAssertEqual(second, material)
    }

    func testValidMaterialRecoveryRemovesCrashLeftoverIssuerKey() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockNodeRecovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let material = try CursorNodeBridgeCertificateManager.ensureMaterial(directory: root)
        let leftover = root.appendingPathComponent(".node-issuer-key.pem")
        try Data("simulated crash residue".utf8).write(to: leftover, options: [.atomic])

        let recovered = try CursorNodeBridgeCertificateManager.ensureMaterial(directory: root)
        XCTAssertEqual(recovered, material)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    }

    func testIssuerIsNameConstrainedAndLeafVerifiesAgainstIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockNodeConstraints-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let material = try CursorNodeBridgeCertificateManager.ensureMaterial(directory: root)
        let issuer = try XCTUnwrap(material.nodeTrustAnchorURL)

        let issuerDetails = try openssl(["x509", "-noout", "-text", "-in", issuer.path])
        XCTAssertTrue(issuerDetails.contains("CA:TRUE"))
        XCTAssertTrue(issuerDetails.contains("pathlen:0"))
        XCTAssertTrue(issuerDetails.contains("X509v3 Name Constraints: critical"))
        XCTAssertTrue(issuerDetails.contains("DNS:api.anthropic.com"))
        XCTAssertTrue(issuerDetails.contains("DNS:.api.anthropic.com"))

        let verification = try openssl([
            "verify", "-CAfile", issuer.path, material.certificateURL.path
        ])
        XCTAssertTrue(verification.contains(": OK"), verification)
    }

    private func openssl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
        return String(decoding: data, as: UTF8.self)
    }
}
