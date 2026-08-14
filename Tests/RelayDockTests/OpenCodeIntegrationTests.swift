import XCTest
@testable import RelayDock

final class OpenCodeIntegrationTests: XCTestCase {
    func testRemovesPendingSensitiveCleanupDirectoriesBeforeGeneration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockOpenCodeCleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cleanup = root.appendingPathComponent(".OpenCode.cleanup.previous", isDirectory: true)
        try FileManager.default.createDirectory(at: cleanup, withIntermediateDirectories: true)
        try Data("old-secret".utf8).write(to: cleanup.appendingPathComponent("key"))

        try OpenCodeIntegration.cleanupPendingSensitiveBackups(parentDirectory: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanup.path))
    }

    func testGeneratesMultipleProvidersAndPrivateKeyFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockOpenCodeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let openAI = GatewayProfile(
            displayName: "OpenAI Gateway",
            provider: .openAICompatible,
            baseURL: "https://openai.example.com/v1",
            models: [GatewayModel(modelID: "gpt-5", displayName: "GPT 5", isVerified: true)]
        )
        let azure = GatewayProfile(
            displayName: "Azure Production",
            provider: .azureOpenAI,
            baseURL: "https://example.openai.azure.com/openai",
            models: [GatewayModel(modelID: "gpt-5-deployment", displayName: "Azure GPT", isVerified: true)],
            azureAPIVersion: "2025-04-01-preview",
            azureDeploymentBasedURLs: true
        )
        let anthropic = GatewayProfile(
            displayName: "Anthropic Gateway",
            provider: .anthropic,
            baseURL: "https://anthropic.example.com/v1",
            models: [GatewayModel(modelID: "claude-sonnet", displayName: "Claude Sonnet", isVerified: true)]
        )
        let responses = GatewayProfile(
            displayName: "Responses Gateway",
            provider: .openAIResponses,
            baseURL: "https://responses.example.com/v1",
            models: [GatewayModel(modelID: "gpt-5", displayName: "GPT 5 Responses", isVerified: true)]
        )

        let configURL = try OpenCodeIntegration.generateConfiguration(
            profiles: [openAI, azure, anthropic, responses],
            apiKeys: [openAI.id: "openai-secret", azure.id: "azure-secret"],
            directory: root
        )
        let data = try Data(contentsOf: configURL)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let providers = try XCTUnwrap(document["provider"] as? [String: Any])
        XCTAssertEqual(providers.count, 4)

        let openAIConfig = try XCTUnwrap(providers[openAI.providerID] as? [String: Any])
        XCTAssertEqual(openAIConfig["npm"] as? String, "@ai-sdk/openai-compatible")
        let azureConfig = try XCTUnwrap(providers[azure.providerID] as? [String: Any])
        XCTAssertEqual(azureConfig["npm"] as? String, "@ai-sdk/azure")
        let azureOptions = try XCTUnwrap(azureConfig["options"] as? [String: Any])
        XCTAssertEqual(azureOptions["apiVersion"] as? String, "2025-04-01-preview")
        XCTAssertEqual(azureOptions["useDeploymentBasedUrls"] as? Bool, true)
        XCTAssertEqual((providers[anthropic.providerID] as? [String: Any])?["npm"] as? String, "@ai-sdk/anthropic")
        XCTAssertEqual((providers[responses.providerID] as? [String: Any])?["npm"] as? String, "@ai-sdk/openai")

        let keyURL = root.appendingPathComponent("keys/\(openAI.id.uuidString.lowercased()).key")
        XCTAssertEqual(try String(contentsOf: keyURL, encoding: .utf8), "openai-secret")
        let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let openAIOptions = try XCTUnwrap(openAIConfig["options"] as? [String: Any])
        XCTAssertEqual(
            openAIOptions["apiKey"] as? String,
            "{file:./keys/\(openAI.id.uuidString.lowercased()).key}"
        )
        let rawConfig = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertFalse(rawConfig.contains("\\/"), rawConfig)
        XCTAssertTrue(rawConfig.contains("{file:./keys/"), rawConfig)
        let references = fileReferences(in: rawConfig)
        XCTAssertEqual(references.count, 2)
        for reference in references {
            XCTAssertTrue(reference.hasPrefix("./keys/"), reference)
            let resolved = configURL.deletingLastPathComponent().appendingPathComponent(reference)
            XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.standardized.path), resolved.path)
        }
    }

    func testAddsV1ToUnversionedOpenAIAndAnthropicGatewayRoots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockOpenCodeVersionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let openAI = GatewayProfile(
            provider: .openAICompatible,
            baseURL: "https://sub2api.example",
            models: [GatewayModel(modelID: "gpt-test", isVerified: true)]
        )
        let anthropic = GatewayProfile(
            provider: .anthropic,
            baseURL: "https://sub2api.example/anthropic",
            models: [GatewayModel(modelID: "claude-test", isVerified: true)]
        )

        let configURL = try OpenCodeIntegration.generateConfiguration(
            profiles: [openAI, anthropic],
            apiKeys: [:],
            directory: root
        )
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        )
        let providers = try XCTUnwrap(document["provider"] as? [String: Any])
        let openAIOptions = try XCTUnwrap(
            (providers[openAI.providerID] as? [String: Any])?["options"] as? [String: Any]
        )
        let anthropicOptions = try XCTUnwrap(
            (providers[anthropic.providerID] as? [String: Any])?["options"] as? [String: Any]
        )
        XCTAssertEqual(openAIOptions["baseURL"] as? String, "https://sub2api.example/v1")
        XCTAssertEqual(
            anthropicOptions["baseURL"] as? String,
            "https://sub2api.example/anthropic/v1"
        )
        XCTAssertNil(anthropicOptions["authToken"])
        XCTAssertNil(anthropicOptions["headers"])
    }

    func testThirdPartyAnthropicKeepsAPIKeyAndAddsBearerAuthorizationHeader() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockOpenCodeAuthTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let anthropic = GatewayProfile(
            provider: .anthropic,
            baseURL: "https://sub2api.example",
            models: [GatewayModel(modelID: "claude-test", isVerified: true)]
        )
        let official = GatewayProfile(
            provider: .anthropic,
            baseURL: "https://api.anthropic.com",
            models: [GatewayModel(modelID: "claude-official", isVerified: true)]
        )

        let configURL = try OpenCodeIntegration.generateConfiguration(
            profiles: [anthropic, official],
            apiKeys: [anthropic.id: "gateway-secret", official.id: "official-secret"],
            directory: root
        )
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        )
        let providers = try XCTUnwrap(document["provider"] as? [String: Any])
        let options = try XCTUnwrap(
            (providers[anthropic.providerID] as? [String: Any])?["options"] as? [String: Any]
        )
        let keyReference = "{file:./keys/\(anthropic.id.uuidString.lowercased()).key}"
        XCTAssertEqual(options["apiKey"] as? String, keyReference)
        XCTAssertNil(options["authToken"])
        let headers = try XCTUnwrap(options["headers"] as? [String: String])
        let bearerURL = root.appendingPathComponent(
            "keys/\(anthropic.id.uuidString.lowercased()).bearer"
        )
        XCTAssertEqual(
            headers["Authorization"],
            "{file:./keys/\(anthropic.id.uuidString.lowercased()).bearer}"
        )
        XCTAssertEqual(
            try String(contentsOf: bearerURL, encoding: .utf8),
            "Bearer gateway-secret"
        )
        let bearerAttributes = try FileManager.default.attributesOfItem(atPath: bearerURL.path)
        XCTAssertEqual((bearerAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let officialOptions = try XCTUnwrap(
            (providers[official.providerID] as? [String: Any])?["options"] as? [String: Any]
        )
        XCTAssertNotNil(officialOptions["apiKey"])
        XCTAssertNil(officialOptions["authToken"])
        XCTAssertNil(officialOptions["headers"])

        let rawConfig = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertFalse(rawConfig.contains("\\/"), rawConfig)
        let references = fileReferences(in: rawConfig)
        XCTAssertEqual(references.count, 3)
        for reference in references {
            XCTAssertTrue(reference.hasPrefix("./keys/"), reference)
            let resolved = configURL.deletingLastPathComponent()
                .appendingPathComponent(reference).standardized
            XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path), resolved.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testSkipsDisabledProfilesAndModels() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockOpenCodeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = GatewayProfile(
            displayName: "Gateway",
            baseURL: "https://gateway.example.com/v1",
            models: [
                GatewayModel(modelID: "enabled", isEnabled: true, isVerified: true),
                GatewayModel(modelID: "disabled", isEnabled: false, isVerified: true)
            ]
        )
        let configURL = try OpenCodeIntegration.generateConfiguration(
            profiles: [profile], apiKeys: [:], directory: root
        )
        let data = try Data(contentsOf: configURL)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let providers = try XCTUnwrap(document["provider"] as? [String: Any])
        let provider = try XCTUnwrap(providers[profile.providerID] as? [String: Any])
        let models = try XCTUnwrap(provider["models"] as? [String: Any])
        XCTAssertNotNil(models["enabled"])
        XCTAssertNil(models["disabled"])

        profile.isEnabled = false
        XCTAssertThrowsError(try OpenCodeIntegration.generateConfiguration(
            profiles: [profile], apiKeys: [:], directory: root
        ))
    }

    func testFailedGenerationPreservesPreviousConfigurationAndKeys() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockOpenCodeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = GatewayProfile(
            displayName: "Working Gateway",
            baseURL: "https://working.example.com/v1",
            models: [GatewayModel(modelID: "working-model", isVerified: true)]
        )
        let configURL = try OpenCodeIntegration.generateConfiguration(
            profiles: [valid], apiKeys: [valid.id: "working-secret"], directory: root
        )
        let originalConfig = try Data(contentsOf: configURL)
        let originalKeyURL = root.appendingPathComponent("keys/\(valid.id.uuidString.lowercased()).key")

        let invalid = GatewayProfile(
            displayName: "Broken Gateway",
            baseURL: "http://remote.example.com",
            models: [GatewayModel(modelID: "broken-model", isVerified: true)]
        )
        XCTAssertThrowsError(try OpenCodeIntegration.generateConfiguration(
            profiles: [valid, invalid],
            apiKeys: [valid.id: "replacement", invalid.id: "broken"],
            directory: root
        ))
        XCTAssertEqual(try Data(contentsOf: configURL), originalConfig)
        XCTAssertEqual(try String(contentsOf: originalKeyURL, encoding: .utf8), "working-secret")
    }

    private func fileReferences(in rawConfig: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"\{file:([^}]+)\}"#)
        let range = NSRange(rawConfig.startIndex..., in: rawConfig)
        return expression.matches(in: rawConfig, range: range).compactMap { match in
            guard let pathRange = Range(match.range(at: 1), in: rawConfig) else { return nil }
            return String(rawConfig[pathRange])
        }
    }
}
