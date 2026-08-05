import XCTest
@testable import RelayDock

final class ModelCatalogParserTests: XCTestCase {
    func testParsesOpenAIAndAnthropicCatalogs() throws {
        let data = Data(#"{"data":[{"id":"gpt-5"},{"id":"claude-sonnet"}]}"#.utf8)
        XCTAssertEqual(ModelCatalogParser.modelIDs(from: data), ["gpt-5", "claude-sonnet"])
    }

    func testParsesAzureDeploymentNames() throws {
        let data = Data(#"{"value":[{"name":"production-gpt"},{"name":"embeddings"}]}"#.utf8)
        XCTAssertEqual(ModelCatalogParser.modelIDs(from: data), ["production-gpt"])
    }

    func testTrimsAndDeduplicatesRootArray() throws {
        let data = Data(#"[" gpt-5 ",{"model_id":"gpt-5"},{"model":"claude"},""]"#.utf8)
        XCTAssertEqual(ModelCatalogParser.modelIDs(from: data), ["gpt-5", "claude"])
    }

    func testInvalidResponseReturnsEmptyCatalog() {
        XCTAssertTrue(ModelCatalogParser.modelIDs(from: Data("not json".utf8)).isEmpty)
    }

    func testUsesAzureCapabilitiesToKeepOnlyTextGenerationModels() {
        let data = Data(#"{"value":[{"name":"chat","capabilities":{"chat_completion":true}},{"name":"vectors","capabilities":{"chat_completion":false,"embeddings":true}}]}"#.utf8)
        XCTAssertEqual(ModelCatalogParser.modelIDs(from: data), ["chat"])
    }

    func testFiltersNonTextModelsFromStringCatalogs() {
        let data = Data(#"["gpt-5","text-embedding-3-small","whisper-1","dall-e-3","gpt-audio-preview","gpt-realtime","sora-2"]"#.utf8)
        XCTAssertEqual(ModelCatalogParser.modelIDs(from: data), ["gpt-5"])
    }

    func testRejectsLegacyCompletionOnlyCapability() {
        let data = Data(#"{"value":[{"name":"curie","capabilities":{"completion":true,"chat_completion":false}}]}"#.utf8)
        XCTAssertTrue(ModelCatalogParser.modelIDs(from: data).isEmpty)
    }

    func testReadsAnthropicPaginationCursor() {
        let data = Data(#"{"data":[{"id":"claude-sonnet"}],"has_more":true,"last_id":"claude-sonnet"}"#.utf8)
        XCTAssertEqual(ModelCatalogParser.nextCursor(from: data), "claude-sonnet")
        XCTAssertNil(ModelCatalogParser.nextCursor(from: Data(#"{"has_more":false,"last_id":"done"}"#.utf8)))
    }
}
