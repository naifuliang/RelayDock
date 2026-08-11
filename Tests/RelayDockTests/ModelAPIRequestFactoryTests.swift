import XCTest
@testable import RelayDock

final class ModelAPIRequestFactoryTests: XCTestCase {
    func testModelVerificationExcludesOnlyDefinitiveModelFailures() {
        XCTAssertTrue(ModelVerificationPolicy.isDefinitivelyUnavailable(
            statusCode: 404,
            responseData: Data(#"{"error":{"message":"model does not exist"}}"#.utf8)
        ))
        XCTAssertTrue(ModelVerificationPolicy.isDefinitivelyUnavailable(
            statusCode: 403,
            responseData: Data(#"{"error":{"message":"no access to this model"}}"#.utf8)
        ))
        XCTAssertFalse(ModelVerificationPolicy.isDefinitivelyUnavailable(
            statusCode: 401,
            responseData: Data(#"{"error":{"message":"invalid API key"}}"#.utf8)
        ))
        XCTAssertFalse(ModelVerificationPolicy.isDefinitivelyUnavailable(
            statusCode: 429,
            responseData: Data(#"{"error":{"message":"model rate limited"}}"#.utf8)
        ))
        XCTAssertFalse(ModelVerificationPolicy.isDefinitivelyUnavailable(
            statusCode: 500,
            responseData: Data(#"{"error":{"message":"model backend unavailable"}}"#.utf8)
        ))
    }

    func testOpenAICatalogAndProbeRequests() throws {
        let profile = GatewayProfile(provider: .openAICompatible, baseURL: "https://gateway.example/v1")
        let catalog = try ModelAPIRequestFactory.catalog(profile: profile, apiKey: "secret")
        XCTAssertEqual(catalog.url?.absoluteString, "https://gateway.example/v1/models")
        XCTAssertEqual(catalog.value(forHTTPHeaderField: "Authorization"), "Bearer secret")

        let probe = try ModelAPIRequestFactory.probe(profile: profile, modelID: "gpt-5", apiKey: "secret")
        XCTAssertEqual(probe.url?.absoluteString, "https://gateway.example/v1/chat/completions")
        XCTAssertEqual(probe.httpMethod, "POST")
        let body = try XCTUnwrap(probe.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-5")
        XCTAssertEqual(json["max_completion_tokens"] as? Int, 1)

        let fallback = try XCTUnwrap(ModelAPIRequestFactory.legacyTokenFallback(
            profile: profile, modelID: "gpt-5", apiKey: "secret"
        ))
        let fallbackData = try XCTUnwrap(fallback.httpBody)
        let fallbackJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: fallbackData) as? [String: Any])
        XCTAssertEqual(fallbackJSON["max_tokens"] as? Int, 1)
        XCTAssertNil(fallbackJSON["max_completion_tokens"])
    }

    func testAnthropicProbeUsesMessagesAndHeaders() throws {
        let profile = GatewayProfile(provider: .anthropic, baseURL: "https://api.anthropic.com/v1")
        let request = try ModelAPIRequestFactory.probe(profile: profile, modelID: "claude-sonnet", apiKey: "ant-key")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "ant-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testThirdPartyAnthropicGatewayAlsoUsesBearerToken() throws {
        let profile = GatewayProfile(provider: .anthropic, baseURL: "https://sub2api.example")
        let request = try ModelAPIRequestFactory.probe(
            profile: profile,
            modelID: "claude-sonnet",
            apiKey: "gateway-key"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "gateway-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gateway-key")
    }

    func testAnthropicCatalogSupportsPaginationCursor() throws {
        let profile = GatewayProfile(provider: .anthropic, baseURL: "https://api.anthropic.com/v1")
        let request = try ModelAPIRequestFactory.catalog(profile: profile, apiKey: "key", afterID: "model-20")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/models?after_id=model-20")
    }

    func testAzureDeploymentRequiresManualIDsAndBuildsProbeURL() throws {
        let profile = GatewayProfile(
            provider: .azureOpenAI,
            baseURL: "https://resource.openai.azure.com/openai",
            azureAPIVersion: "2024-10-21",
            azureDeploymentBasedURLs: true
        )
        XCTAssertThrowsError(try ModelAPIRequestFactory.catalog(profile: profile, apiKey: "azure-key")) { error in
            XCTAssertEqual(error as? ModelAPIError, .azureDeploymentCatalogUnavailable)
        }

        let probe = try ModelAPIRequestFactory.probe(profile: profile, modelID: "gpt prod", apiKey: "azure-key")
        XCTAssertEqual(
            probe.url?.absoluteString,
            "https://resource.openai.azure.com/openai/deployments/gpt%20prod/chat/completions?api-version=2024-10-21"
        )
    }

    func testResponsesProviderUsesResponsesEndpoint() throws {
        let profile = GatewayProfile(provider: .openAIResponses, baseURL: "https://gateway.example")
        let request = try ModelAPIRequestFactory.probe(profile: profile, modelID: "gpt-5", apiKey: "key")
        XCTAssertEqual(request.url?.absoluteString, "https://gateway.example/v1/responses")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["max_output_tokens"] as? Int, 16)
    }

    func testArkCodingPlanVersionedRootDoesNotGainAnExtraV1() throws {
        let profile = EndpointPreset.arkCodingPlan.makeProfile()
        let catalog = try ModelAPIRequestFactory.catalog(profile: profile, apiKey: "ark-secret")
        XCTAssertEqual(catalog.url?.absoluteString, "https://ark.cn-beijing.volces.com/api/coding/v3/models")
        XCTAssertEqual(catalog.value(forHTTPHeaderField: "Authorization"), "Bearer ark-secret")

        let probe = try ModelAPIRequestFactory.probe(
            profile: profile,
            modelID: "ark-code-latest",
            apiKey: "ark-secret"
        )
        XCTAssertEqual(
            probe.url?.absoluteString,
            "https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions"
        )
    }
}
