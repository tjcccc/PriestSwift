import XCTest
@testable import Priest

final class Protocol29Tests: XCTestCase {
    func testResponsesPlacesProviderToolsBeforeFunctionTools() {
        let provider = OpenAIResponsesProvider()
        let body = provider.buildPayload(
            messages: [ChatMessage(role: "user", content: "Search")],
            config: PriestConfig(provider: "responses", model: "gpt-test"),
            outputSpec: OutputSpec(),
            options: AdapterCallOptions(
                tools: [ToolDefinition(name: "lookup")],
                providerTools: [.webSearch]
            ),
            stream: false
        )

        let tools = body["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?[0]["type"] as? String, "web_search")
        XCTAssertEqual(tools?[1]["type"] as? String, "function")
    }

    func testUnsupportedProviderToolReturnsProviderError() async throws {
        let engine = PriestEngine(
            profileLoader: FilesystemProfileLoader(),
            adapters: ["mock": MockAdapter()]
        )
        let response = try await engine.run(PriestRequest(
            config: PriestConfig(provider: "mock", model: "test-model"),
            prompt: "Search",
            providerTools: [.webSearch]
        ))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, PriestErrorCode.providerError.rawValue)
        XCTAssertTrue(response.error?.message.contains(
            "Provider tool 'web_search' is not supported"
        ) == true)
    }
}
