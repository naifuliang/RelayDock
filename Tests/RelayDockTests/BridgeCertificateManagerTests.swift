import Foundation
import XCTest
@testable import RelayDock

final class BridgeCertificateManagerTests: XCTestCase {
    func testSubjectAlternativeNameMustContainOnlyAnthropicHost() {
        let exact = """
        X509v3 Subject Alternative Name:
            DNS:api.anthropic.com
        """
        XCTAssertEqual(
            BridgeCertificateManager.certificateDNSNames(from: exact),
            ["api.anthropic.com"]
        )

        let overbroad = """
        X509v3 Subject Alternative Name:
            DNS:api.anthropic.com, DNS:example.com
        """
        XCTAssertNotEqual(
            BridgeCertificateManager.certificateDNSNames(from: overbroad),
            ["api.anthropic.com"]
        )
    }

    func testParsesEveryPEMCertificateForTrustCleanup() {
        let first = """
        -----BEGIN CERTIFICATE-----
        Zmlyc3Q=
        -----END CERTIFICATE-----
        """
        let second = """
        -----BEGIN CERTIFICATE-----
        c2Vjb25k
        -----END CERTIFICATE-----
        """
        let parsed = BridgeCertificateManager.pemCertificates(
            from: "noise before\n\(first)\nnoise between\n\(second)\nnoise after"
        )
        XCTAssertEqual(parsed.count, 2)
        XCTAssertTrue(String(decoding: parsed[0], as: UTF8.self).contains("Zmlyc3Q="))
        XCTAssertTrue(String(decoding: parsed[1], as: UTF8.self).contains("c2Vjb25k"))
    }

    func testDistinguishesMissingTrustSettingFromOtherKeychainErrors() {
        XCTAssertTrue(BridgeCertificateManager.isMissingTrustSetting(
            "SecTrustSettingsRemoveTrustSettings: The specified item could not be found in the keychain."
        ))
        XCTAssertFalse(BridgeCertificateManager.isMissingTrustSetting(
            "User interaction is not allowed."
        ))
    }

    func testGeneratedCertificateIsDomainScopedNonCAAndStable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockCertificateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try BridgeCertificateManager.ensureMaterial(directory: directory)
        XCTAssertTrue(try BridgeCertificateManager.validate(first))
        let firstCertificate = try Data(contentsOf: first.certificateURL)
        let firstKey = try Data(contentsOf: first.privateKeyURL)

        let second = try BridgeCertificateManager.ensureMaterial(directory: directory)
        XCTAssertEqual(try Data(contentsOf: second.certificateURL), firstCertificate)
        XCTAssertEqual(try Data(contentsOf: second.privateKeyURL), firstKey)

        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let keyPermissions = try FileManager.default.attributesOfItem(atPath: first.privateKeyURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryPermissions?.intValue, 0o700)
        XCTAssertEqual(keyPermissions?.intValue, 0o600)
    }

    func testPartialCertificateMaterialFailsClosedWithoutRotation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockCertificateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let certificateURL = directory.appendingPathComponent("api.anthropic.com.pem")
        try Data("partial".utf8).write(to: certificateURL)

        XCTAssertThrowsError(try BridgeCertificateManager.ensureMaterial(directory: directory))
        XCTAssertEqual(try Data(contentsOf: certificateURL), Data("partial".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("api.anthropic.com-key.pem").path
        ))
    }
}
