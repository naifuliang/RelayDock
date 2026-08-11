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

    func testTrustInstallationUsesRootResultScopedToAnthropicSSLHostAndLoginKeychain() {
        let certificateURL = URL(fileURLWithPath: "/tmp/relaydock-test.pem")
        let arguments = BridgeCertificateManager.trustInstallationArguments(
            certificateURL: certificateURL,
            keychainPath: "/Users/test/Library/Keychains/login.keychain-db"
        )

        XCTAssertEqual(arguments, [
            "add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-s", "api.anthropic.com",
            "-k", "/Users/test/Library/Keychains/login.keychain-db", certificateURL.path
        ])
        XCTAssertFalse(arguments.contains("trustAsRoot"))
    }

    func testFailedPostInstallVerificationRollsBackTrust() {
        var rolledBack = false

        XCTAssertThrowsError(try BridgeCertificateManager.requireTrustedAfterInstallation(
            verification: { false },
            rollback: { rolledBack = true }
        )) { error in
            guard case BridgeCertificateError.trustVerificationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(rolledBack)
    }

    func testPostInstallRollbackFailureReportsBothErrors() {
        struct RollbackFailure: LocalizedError {
            var errorDescription: String? { "rollback failed" }
        }

        XCTAssertThrowsError(try BridgeCertificateManager.requireTrustedAfterInstallation(
            verification: { false },
            rollback: { throw RollbackFailure() }
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("证书信任验证失败"))
            XCTAssertTrue(error.localizedDescription.contains("rollback failed"))
        }
    }

    func testCertificateSearchUsesExplicitDefaultKeychain() {
        XCTAssertEqual(
            BridgeCertificateManager.certificateSearchArguments(
                keychainPath: "/Users/test/Library/Keychains/login.keychain-db"
            ),
            [
                "find-certificate", "-a", "-c", "RelayDock Anthropic Bridge", "-p",
                "/Users/test/Library/Keychains/login.keychain-db"
            ]
        )
    }

    func testParsesQuotedDefaultKeychainPathAndRejectsInvalidOutput() {
        XCTAssertEqual(
            BridgeCertificateManager.keychainPath(
                fromDefaultKeychainOutput: "    \"/Users/test/Library/Keychains/login.keychain-db\"\n"
            ),
            "/Users/test/Library/Keychains/login.keychain-db"
        )
        XCTAssertNil(BridgeCertificateManager.keychainPath(fromDefaultKeychainOutput: "login.keychain-db"))
        XCTAssertNil(BridgeCertificateManager.keychainPath(fromDefaultKeychainOutput: ""))
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
