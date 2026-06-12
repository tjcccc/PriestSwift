import XCTest
@testable import Priest

/// Tool calling and tool loop tests (spec 2.4.0).
final class ToolCallingTests: XCTestCase {
    private let config = PriestConfig(provider: "mock", model: "test-model")
    private let readFileTool = ToolDefinition(name: "read_file", description: "Read a file")

    private var readFileCall: ToolCall {
        ToolCall(id: "call_0", name: "read_file", arguments: ["path": .string("a.txt")])
    }

    private func makeEngine(_ adapter: any ProviderAdapter, store: (any SessionStore)? = nil) -> PriestEngine {
        PriestEngine(
            profileLoader: FilesystemProfileLoader(),
            sessionStore: store,
            adapters: ["mock": adapter]
        )
    }

    private func makeRequest() -> PriestRequest {
        PriestRequest(config: config, prompt: "Read a.txt", tools: [readFileTool])
    }

    func testToolCallsSurfaceWithFinishedReason() async throws {
        let adapter = ScriptedAdapter(results: [
            AdapterResult(text: "", finishReason: "tool_calls", toolCalls: [readFileCall]),
        ])
        let response = try await makeEngine(adapter).run(makeRequest())

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.toolCalls?.first?.name, "read_file")
        XCTAssertEqual(response.execution.finishedReason, .toolCalls)
        XCTAssertEqual(adapter.calls[0].options?.tools.first?.name, "read_file")
    }

    func testToolExchangeReplayedAfterUserMessage() async throws {
        let adapter = ScriptedAdapter(results: [AdapterResult(text: "done", finishReason: "stop")])
        var request = makeRequest()
        request.toolExchange = [
            .assistant(text: "", toolCalls: [readFileCall]),
            .toolResult(toolCallId: "call_0", name: "read_file", content: "file body"),
        ]
        _ = try await makeEngine(adapter).run(request)

        let messages = adapter.calls[0].messages
        XCTAssertEqual(messages[messages.count - 3].role, "user")
        XCTAssertEqual(messages[messages.count - 2].role, "assistant")
        XCTAssertNotNil(messages[messages.count - 2].toolCalls)
        XCTAssertEqual(messages[messages.count - 1].role, "tool")
        XCTAssertEqual(messages[messages.count - 1].toolCallId, "call_0")
        XCTAssertEqual(messages[messages.count - 1].content, "file body")
    }

    func testSessionNotPersistedWhileToolCallsPending() async throws {
        let store = InMemorySessionStore()
        let adapter = ScriptedAdapter(results: [
            AdapterResult(text: "", finishReason: "tool_calls", toolCalls: [readFileCall]),
            AdapterResult(text: "The file says hello.", finishReason: "stop"),
        ])
        let engine = makeEngine(adapter, store: store)

        var request = makeRequest()
        request.session = SessionRef(id: "s1")
        let first = try await engine.run(request)
        XCTAssertNotNil(first.toolCalls)
        let afterFirst = try await store.get("s1")
        XCTAssertEqual(afterFirst?.turns.count, 0)

        request.toolExchange = [
            .assistant(text: nil, toolCalls: first.toolCalls!),
            .toolResult(toolCallId: "call_0", name: "read_file", content: "hello"),
        ]
        let second = try await engine.run(request)
        XCTAssertEqual(second.text, "The file says hello.")

        let session = try await store.get("s1")
        XCTAssertEqual(session?.turns.count, 2)
        XCTAssertEqual(session?.turns.first?.role, .user)
        XCTAssertEqual(session?.turns.first?.content, "Read a.txt")
    }

    func testRunWithToolsExecutesAndReturnsFinalResponse() async throws {
        let adapter = ScriptedAdapter(results: [
            AdapterResult(text: "", finishReason: "tool_calls", toolCalls: [readFileCall]),
            AdapterResult(text: "The file says hello.", finishReason: "stop"),
        ])
        let engine = makeEngine(adapter)

        let result = try await runWithTools(
            engine: engine,
            request: makeRequest(),
            executor: { _ in ToolExecutionResult(content: "hello") }
        )

        XCTAssertEqual(result.response.text, "The file says hello.")
        XCTAssertFalse(result.iterationLimitReached)
        guard case .assistant = result.exchange[0] else { return XCTFail("expected assistant turn") }
        guard case let .toolResult(_, _, content, isError) = result.exchange[1] else {
            return XCTFail("expected tool result turn")
        }
        XCTAssertEqual(content, "hello")
        XCTAssertFalse(isError)
        XCTAssertTrue(adapter.calls[1].messages.contains { $0.role == "tool" })
    }

    func testRunWithToolsDenialInjectsErrorResult() async throws {
        let adapter = ScriptedAdapter(results: [
            AdapterResult(text: "", finishReason: "tool_calls", toolCalls: [readFileCall]),
            AdapterResult(text: "Understood.", finishReason: "stop"),
        ])
        let engine = makeEngine(adapter)

        let result = try await runWithTools(
            engine: engine,
            request: makeRequest(),
            executor: { _ in
                XCTFail("executor must not run for denied calls")
                return ToolExecutionResult(content: "never")
            },
            onToolCall: { _ in ApprovalDecision(approved: false, reason: "not allowed") }
        )

        guard case let .toolResult(_, _, content, isError) = result.exchange[1] else {
            return XCTFail("expected tool result turn")
        }
        XCTAssertTrue(isError)
        XCTAssertTrue(content.contains("not allowed"))
    }

    func testRunWithToolsIterationCap() async throws {
        let adapter = ScriptedAdapter(results: [
            AdapterResult(text: "", finishReason: "tool_calls", toolCalls: [readFileCall]),
        ])
        let engine = makeEngine(adapter)

        let result = try await runWithTools(
            engine: engine,
            request: makeRequest(),
            executor: { _ in ToolExecutionResult(content: "data") },
            maxIterations: 3
        )

        XCTAssertTrue(result.iterationLimitReached)
        XCTAssertEqual(adapter.calls.count, 3)
    }

    func testStreamEventsFallbackWrapsPlainStream() async throws {
        let engine = makeEngine(MockStreamingAdapter(text: "hello world"))
        var deltas: [String] = []
        var doneResponse: PriestResponse?

        for try await event in engine.streamEvents(PriestRequest(config: config, prompt: "Hi")) {
            if event.type == "text_delta", let text = event.text { deltas.append(text) }
            if event.type == "done" { doneResponse = event.response }
        }

        XCTAssertEqual(deltas, ["hello", "world"])
        XCTAssertEqual(doneResponse?.text, "helloworld")
        XCTAssertEqual(doneResponse?.ok, true)
    }
}
