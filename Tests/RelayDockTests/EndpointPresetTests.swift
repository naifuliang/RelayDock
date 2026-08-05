import XCTest
@testable import RelayDock

final class EndpointPresetTests: XCTestCase {
    func testDefaultGatewayNameIsGatewayOne() {
        XCTAssertEqual(EndpointProfile().displayName, "Gateway 1")
        XCTAssertEqual(GatewayProfile().displayName, "Gateway 1")
        XCTAssertTrue(GatewayProfile().isPristineDefault)
    }

    func testExistingUserGatewayNameIsNeverRenamed() throws {
        let original = GatewayProfile(displayName: "Sub2API", baseURL: "https://gateway.example/v1")
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(GatewayProfile.self, from: data)

        XCTAssertEqual(restored.displayName, "Sub2API")
        XCTAssertFalse(restored.isPristineDefault)
    }

    func testOfficialConnectionPresetsUseExpectedProtocolsAndEndpoints() {
        let openAI = EndpointPreset.openAI.makeProfile()
        XCTAssertEqual(openAI.displayName, "OpenAI API")
        XCTAssertEqual(openAI.provider, .openAIResponses)
        XCTAssertEqual(openAI.baseURL, "https://api.openai.com/v1")

        let kimi = EndpointPreset.kimi.makeProfile()
        XCTAssertEqual(kimi.provider, .openAICompatible)
        XCTAssertEqual(kimi.baseURL, "https://api.kimi.com/coding/v1")
        XCTAssertEqual(kimi.models.map(\.modelID), ["kimi-for-coding"])

        let ark = EndpointPreset.arkCodingPlan.makeProfile()
        XCTAssertEqual(ark.provider, .openAICompatible)
        XCTAssertEqual(ark.baseURL, "https://ark.cn-beijing.volces.com/api/coding/v3")
        XCTAssertEqual(ark.models.map(\.modelID), ["ark-code-latest"])
    }

    func testPresetMatchingRequiresBothProtocolAndEndpoint() {
        XCTAssertEqual(EndpointPreset.matching(EndpointPreset.kimi.makeProfile()), .kimi)
        var customized = EndpointPreset.kimi.makeProfile()
        customized.baseURL = "https://proxy.example/v1"
        XCTAssertNil(EndpointPreset.matching(customized))
    }

    @MainActor
    func testDiscardedKeyDoesNotPreventPresetFromReplacingPristineDefault() {
        let suiteName = "EndpointPresetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, scheduleAutomaticUpdateCheck: false)
        let defaultID = model.selectedProfileID

        model.apiKey = "unsaved-secret"
        model.discardSelectedProfileChanges()
        model.addProfile(from: .kimi)

        XCTAssertEqual(model.profiles.count, 1)
        XCTAssertEqual(model.profiles[0].id, defaultID)
        XCTAssertEqual(model.profiles[0].baseURL, "https://api.kimi.com/coding/v1")
        XCTAssertEqual(model.apiKey, "")
    }
}
