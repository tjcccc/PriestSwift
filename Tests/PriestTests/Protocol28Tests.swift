import Foundation
import XCTest
@testable import Priest

final class Protocol28Tests: XCTestCase {
    private let provider = OpenAIResponsesProvider()

    func testResponsesPayloadMapsReasoningSchemaToolsAndProtectsInvariants() {
        let config = PriestConfig(
            provider: "responses",
            model: "gpt-test",
            maxOutputTokens: 200,
            reasoning: ReasoningConfig(
                enabled: true,
                effort: .medium,
                summary: .auto
            ),
            providerOptions: [
                "model": "wrong",
                "stream": true,
                "store": true,
            ]
        )
        let output = OutputSpec(
            jsonSchema: ["type": "object"],
            jsonSchemaName: "classification",
            jsonSchemaStrict: true
        )
        let options = AdapterCallOptions(tools: [
            ToolDefinition(
                name: "lookup",
                description: "Look up a label.",
                parameters: ["type": "object"]
            ),
        ])

        let body = provider.buildPayload(
            messages: [ChatMessage(role: "user", content: "Classify.")],
            config: config,
            outputSpec: output,
            options: options,
            stream: false
        )

        XCTAssertEqual(body["model"] as? String, "gpt-test")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["store"] as? Bool, true)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 200)
        let reasoning = body["reasoning"] as? [String: Any]
        XCTAssertEqual(reasoning?["effort"] as? String, "medium")
        XCTAssertEqual(reasoning?["summary"] as? String, "auto")
        let text = body["text"] as? [String: Any]
        let format = text?["format"] as? [String: Any]
        XCTAssertEqual(format?["name"] as? String, "classification")
        let tools = body["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.first?["type"] as? String, "function")
    }

    func testResponsesContinuationPrecedesFunctionCallAndResult() {
        let reasoning = ReasoningInfo(continuation: [
            OpaqueReasoningState(
                format: "openai.responses.reasoning.v1",
                value: [
                    "type": "reasoning",
                    "id": "rs_1",
                    "encrypted_content": "opaque",
                ]
            ),
        ])
        let messages = [
            ChatMessage(
                role: "assistant",
                content: "",
                toolCalls: [
                    ToolCall(id: "call_1", name: "lookup", arguments: ["id": "42"]),
                ],
                reasoning: reasoning
            ),
            ChatMessage(
                role: "tool",
                content: "found",
                toolCallId: "call_1",
                name: "lookup"
            ),
        ]
        let body = provider.buildPayload(
            messages: messages,
            config: PriestConfig(provider: "responses", model: "gpt-test"),
            outputSpec: OutputSpec(),
            options: nil,
            stream: false
        )
        let input = body["input"] as? [[String: Any]]
        XCTAssertEqual(input?[0]["type"] as? String, "reasoning")
        XCTAssertEqual(input?[1]["type"] as? String, "function_call")
        XCTAssertEqual(input?[1]["arguments"] as? String, #"{"id":"42"}"#)
        XCTAssertEqual(input?[2]["type"] as? String, "function_call_output")
    }

    func testResponsesParserSurfacesSafeReasoningUsageAndContentFilter() throws {
        let result = try OpenAIResponsesProvider.parseResponse([
            "status": "completed",
            "output": [
                [
                    "type": "reasoning",
                    "id": "rs_1",
                    "summary": [["type": "summary_text", "text": "Checked two options."]],
                    "encrypted_content": "opaque",
                ],
                [
                    "type": "function_call",
                    "call_id": "call_1",
                    "name": "lookup",
                    "arguments": #"{"id":"42"}"#,
                ],
            ],
            "usage": [
                "input_tokens": 100,
                "input_tokens_details": ["cached_tokens": 80],
                "output_tokens": 25,
                "output_tokens_details": ["reasoning_tokens": 20],
            ],
        ])

        XCTAssertEqual(result.finishReason, "tool_calls")
        XCTAssertEqual(result.reasoning?.summary, "Checked two options.")
        XCTAssertEqual(result.reasoning?.continuation?.first?.format, "openai.responses.reasoning.v1")
        XCTAssertEqual(result.reasoningTokens, 20)
        XCTAssertEqual(result.toolCalls?.first?.arguments["id"], "42")

        let filtered = try OpenAIResponsesProvider.parseResponse([
            "status": "incomplete",
            "incomplete_details": ["reason": "content_filter"],
            "output": [],
        ])
        XCTAssertEqual(filtered.finishReason, "content_filter")
    }

    func testResponsesParserDoesNotExposeRawReasoning() throws {
        let result = try OpenAIResponsesProvider.parseResponse([
            "status": "completed",
            "output": [
                [
                    "type": "reasoning",
                    "id": "rs_raw",
                    "content": [["type": "reasoning_text", "text": "private trace"]],
                ],
                [
                    "type": "function_call",
                    "call_id": "call_1",
                    "name": "lookup",
                    "arguments": "{}",
                ],
            ],
        ])
        XCTAssertNil(result.reasoning)
    }

    func testResponsesSemanticSSEHandlesCRLFAndDeduplicatesToolEnd() throws {
        let body =
            "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"Checking\"}\r\n\r\n"
            + "data: {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"lookup\",\"arguments\":\"\"}}\r\n\r\n"
            + "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"{\\\"id\\\":\\\"42\\\"}\"}\r\n\r\n"
            + "data: {\"type\":\"response.function_call_arguments.done\",\"output_index\":1,\"arguments\":\"{\\\"id\\\":\\\"42\\\"}\",\"name\":\"lookup\"}\r\n\r\n"
            + "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"lookup\",\"arguments\":\"{\\\"id\\\":\\\"42\\\"}\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}}\r\n\r\n"

        let events = try OpenAIResponsesProvider.parseSSE(body)
        XCTAssertTrue(events.contains {
            $0.type == "reasoning_summary_delta" && $0.text == "Checking"
        })
        XCTAssertEqual(events.filter { $0.type == "tool_call_end" }.count, 1)
        XCTAssertEqual(events.first { $0.type == "usage" }?.inputTokens, 10)
        XCTAssertEqual(events.last?.finishReason, "tool_calls")
    }

    func testAnthropicAndOllamaMapNeutralReasoning() {
        let anthropic = AnthropicProvider(apiKey: "test")
        let continuation = ReasoningInfo(continuation: [
            OpaqueReasoningState(
                format: "anthropic.messages.thinking.v1",
                value: [
                    "type": "thinking",
                    "thinking": "Checked.",
                    "signature": "opaque",
                ]
            ),
        ])
        let anthropicBody = anthropic.buildPayload(
            messages: [
                ChatMessage(
                    role: "assistant",
                    content: "",
                    toolCalls: [ToolCall(id: "call_1", name: "lookup")],
                    reasoning: continuation
                ),
            ],
            config: PriestConfig(
                provider: "anthropic",
                model: "claude-test",
                reasoning: ReasoningConfig(
                    enabled: true,
                    effort: .high,
                    summary: .auto
                )
            ),
            outputSpec: OutputSpec(),
            options: nil
        )
        let thinking = anthropicBody["thinking"] as? [String: Any]
        XCTAssertEqual(thinking?["type"] as? String, "adaptive")
        XCTAssertEqual(thinking?["display"] as? String, "summarized")
        let outputConfig = anthropicBody["output_config"] as? [String: Any]
        XCTAssertEqual(outputConfig?["effort"] as? String, "high")
        let turns = anthropicBody["messages"] as? [[String: Any]]
        let blocks = turns?.first?["content"] as? [[String: Any]]
        XCTAssertEqual(blocks?[0]["type"] as? String, "thinking")
        XCTAssertEqual(blocks?[1]["type"] as? String, "tool_use")

        let ollama = OllamaProvider()
        let ollamaBody = ollama.buildPayload(
            messages: [ChatMessage(role: "user", content: "Hi")],
            config: PriestConfig(
                provider: "ollama",
                model: "qwen",
                reasoning: ReasoningConfig(effort: .high),
                providerOptions: ["think": false]
            ),
            outputSpec: OutputSpec(),
            options: nil,
            stream: false
        )
        XCTAssertEqual(ollamaBody["think"] as? Bool, false)
    }

    func testOllamaRejectsUnsupportedReasoningEffortBeforeTransport() async {
        let ollama = OllamaProvider()
        do {
            _ = try await ollama.complete(
                messages: [ChatMessage(role: "user", content: "Hi")],
                config: PriestConfig(
                    provider: "ollama",
                    model: "qwen",
                    reasoning: ReasoningConfig(effort: .minimal)
                ),
                outputSpec: OutputSpec()
            )
            XCTFail("expected request validation to fail")
        } catch let error as PriestError {
            XCTAssertEqual(error.code, .requestInvalid)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEngineForwardsStructuredReasoningEventsAndUsage() async throws {
        let engine = PriestEngine(
            profileLoader: FilesystemProfileLoader(),
            adapters: ["reasoning-stream": ReasoningStreamingAdapter()]
        )
        var events: [PriestStreamEvent] = []
        for try await event in engine.streamEvents(PriestRequest(
            config: PriestConfig(provider: "reasoning-stream", model: "test-model"),
            prompt: "Plan"
        )) {
            events.append(event)
        }

        XCTAssertEqual(
            events.first { $0.type == "reasoning_summary_delta" }?.text,
            "Checked the plan."
        )
        XCTAssertEqual(events.first { $0.type == "usage" }?.reasoningTokens, 4)
        let response = events.last { $0.type == "done" }?.response
        XCTAssertEqual(response?.reasoning?.summary, "Checked the plan.")
        XCTAssertEqual(response?.usage?.reasoningTokens, 4)
        XCTAssertEqual(response?.usage?.totalTokens, 15)
    }

    func testEngineAndToolLoopPropagateReasoning() async throws {
        let reasoning = ReasoningInfo(
            summary: "Used the lookup plan.",
            continuation: [
                OpaqueReasoningState(
                    format: "test.reasoning.v1",
                    value: ["opaque": true]
                ),
            ]
        )
        let adapter = ScriptedAdapter(results: [
            AdapterResult(
                text: "",
                finishReason: "tool_calls",
                toolCalls: [ToolCall(id: "call_1", name: "lookup")],
                reasoningTokens: 7,
                reasoning: reasoning
            ),
            AdapterResult(text: "done", finishReason: "stop"),
        ])
        let engine = PriestEngine(
            profileLoader: FilesystemProfileLoader(),
            adapters: ["mock": adapter]
        )
        let result = try await runWithTools(
            engine: engine,
            request: PriestRequest(
                config: PriestConfig(provider: "mock", model: "test-model"),
                prompt: "Use a tool",
                tools: [ToolDefinition(name: "lookup")]
            ),
            executor: { _ in ToolExecutionResult(content: "found") }
        )

        guard case let .assistant(_, _, exchangeReasoning) = result.exchange[0] else {
            return XCTFail("expected assistant exchange")
        }
        XCTAssertEqual(exchangeReasoning, reasoning)
        XCTAssertEqual(
            adapter.calls[1].messages.first { $0.role == "assistant" }?.reasoning,
            reasoning
        )
    }
}

private struct ReasoningStreamingAdapter: ProviderAdapter {
    let providerName = "reasoning-stream"

    func complete(
        messages: [ChatMessage],
        config: PriestConfig,
        outputSpec: OutputSpec,
        options: AdapterCallOptions?
    ) async throws -> AdapterResult {
        AdapterResult(text: "done", finishReason: "stop")
    }

    func streamEvents(
        messages: [ChatMessage],
        config: PriestConfig,
        outputSpec: OutputSpec,
        options: AdapterCallOptions?
    ) -> AsyncThrowingStream<AdapterStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            var reasoning = AdapterStreamEvent(type: "reasoning_summary_delta")
            reasoning.text = "Checked the plan."
            continuation.yield(reasoning)

            var text = AdapterStreamEvent(type: "text_delta")
            text.text = "done"
            continuation.yield(text)

            var usage = AdapterStreamEvent(type: "usage")
            usage.inputTokens = 10
            usage.outputTokens = 5
            usage.reasoningTokens = 4
            continuation.yield(usage)

            var finish = AdapterStreamEvent(type: "finish")
            finish.finishReason = "stop"
            finish.reasoning = ReasoningInfo(summary: "Checked the plan.")
            continuation.yield(finish)
            continuation.finish()
        }
    }
}
