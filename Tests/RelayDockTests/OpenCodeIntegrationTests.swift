import XCTest
@testable import RelayDock

final class OpenCodeIntegrationTests: XCTestCase {
    func testGeneratesMultipleProvidersAndPrivateKeyFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockOpenCodeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let openAI = GatewayProfile(
            displayName: "OpenAI Gateway",
            provider: .openAICompatible,
            baseURL: "https://openai.example.com/v1",
            models: [GatewayModel(modelID: "gpt-5", displayName: "GPT 5")]
        )
        let azure = GatewayProfile(
            displayName: "Azure Production",
            provider: .azureOpenAI,
            baseURL: "https://example.openai.azure.com/openai",
            models: [GatewayModel(modelID: "gpt-5-deployment", displayName: "Azure GPT")],
            azureAPIVersion: "2025-04-01-preview",
            azureDeploymentBasedURLs: true
        )
        let anthropic = GatewayProfile(
            displayName: "Anthropic Gateway",
            provider: .anthropic,
            baseURL: "https://anthropic.example.com/v1",
            models: [GatewayModel(modelID: "claude-sonnet", displayName: "Claude Sonnet")]
        )
        let responses = GatewayProfile(
            displayName: "Responses Gateway",
            provider: .openAIResponses,
            baseURL: "https://responses.example.com/v1",
            models: [GatewayModel(modelID: "gpt-5", displayName: "GPT 5 Responses")]
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
        XCTAssertEqual(openAIOptions["apiKey"] as? String, "{file:\(keyURL.path)}")
    }

    func testSkipsDisabledProfilesAndModels() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDockOpenCodeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = GatewayProfile(
            displayName: "Gateway",
            baseURL: "https://gateway.example.com/v1",
            models: [
                GatewayModel(modelID: "enabled", isEnabled: true),
                GatewayModel(modelID: "disabled", isEnabled: false)
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
            models: [GatewayModel(modelID: "working-model")]
        )
        let configURL = try OpenCodeIntegration.generateConfiguration(
            profiles: [valid], apiKeys: [valid.id: "working-secret"], directory: root
        )
        let originalConfig = try Data(contentsOf: configURL)
        let originalKeyURL = root.appendingPathComponent("keys/\(valid.id.uuidString.lowercased()).key")

        let invalid = GatewayProfile(
            displayName: "Broken Gateway",
            baseURL: "http://remote.example.com",
            models: [GatewayModel(modelID: "broken-model")]
        )
        XCTAssertThrowsError(try OpenCodeIntegration.generateConfiguration(
            profiles: [valid, invalid],
            apiKeys: [valid.id: "replacement", invalid.id: "broken"],
            directory: root
        ))
        XCTAssertEqual(try Data(contentsOf: configURL), originalConfig)
        XCTAssertEqual(try String(contentsOf: originalKeyURL, encoding: .utf8), "working-secret")
    }
}
