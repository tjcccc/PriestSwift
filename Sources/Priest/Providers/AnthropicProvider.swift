import Foundation

/// Provider adapter for Anthropic's /v1/messages endpoint.
///
/// Anthropic's API shape differs from OpenAI: system content is a top-level
/// field, not a message in the array, and auth uses x-api-key header.
///
/// Supports native SSE streaming via URLSession.bytes.
/// See `behavior/providers.md` for the full translation specification.
public final class AnthropicProvider: ProviderAdapter {
    public let providerName = "anthropic"
    private let apiKey: String
    private let baseURL: URL

    private static let apiVersion = "2023-06-01"
    private static let defaultMaxTokens = 8096
    private static let reasoningFormat = "anthropic.messages.thinking.v1"

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    // MARK: - complete

    public func complete(
        messages: [ChatMessage],
        config: PriestConfig,
        outputSpec: OutputSpec,
        options: AdapterCallOptions? = nil
    ) async throws -> AdapterResult {
        let payload = buildPayload(messages: messages, config: config, outputSpec: outputSpec, options: options)
        let data = try await post(path: "/v1/messages", payload: payload, timeout: config.timeoutSeconds)
        let json = try parseJSON(data)
        let contentBlocks = json["content"] as? [[String: Any]] ?? []
        let text = contentBlocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        let toolCalls = Self.parseToolUseBlocks(contentBlocks)
        let reasoning = Self.parseReasoning(contentBlocks, includeContinuation: toolCalls != nil)
        let usage = json["usage"] as? [String: Any]
        let outputDetails = usage?["output_tokens_details"] as? [String: Any]
        return AdapterResult(
            text: text,
            finishReason: toolCalls != nil ? "tool_calls" : mapFinishReason(json["stop_reason"] as? String),
            inputTokens: usage?["input_tokens"] as? Int,
            outputTokens: usage?["output_tokens"] as? Int,
            cachedInputTokens: usage?["cache_read_input_tokens"] as? Int,
            toolCalls: toolCalls,
            reasoningTokens: outputDetails?["thinking_tokens"] as? Int,
            reasoning: reasoning
        )
    }

    // MARK: - stream

    public func stream(
        messages: [ChatMessage],
        config: PriestConfig,
        outputSpec: OutputSpec,
        options: AdapterCallOptions? = nil
    ) -> AsyncThrowingStream<String, Error> {
        var payload = buildPayload(messages: messages, config: config, outputSpec: outputSpec, options: options)
        payload["stream"] = true
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = try self.buildRequest(path: "/v1/messages", payload: payload, timeout: config.timeoutSeconds)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw PriestError.providerError(self.providerName, message: "No HTTP response")
                    }
                    try self.checkStatus(httpResponse, provider: self.providerName)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let raw = String(line.dropFirst(6))
                        guard let data = raw.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if obj["type"] as? String == "content_block_delta",
                           let delta = obj["delta"] as? [String: Any],
                           let text = delta["text"] as? String, !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch let e as PriestError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: PriestError.providerError(self.providerName, message: error.localizedDescription))
                }
            }
        }
    }

    public func streamEvents(
        messages: [ChatMessage],
        config: PriestConfig,
        outputSpec: OutputSpec,
        options: AdapterCallOptions? = nil
    ) -> AsyncThrowingStream<AdapterStreamEvent, Error> {
        var payload = buildPayload(
            messages: messages,
            config: config,
            outputSpec: outputSpec,
            options: options
        )
        payload["stream"] = true
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = try self.buildRequest(
                        path: "/v1/messages",
                        payload: payload,
                        timeout: config.timeoutSeconds
                    )
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw PriestError.providerError(self.providerName, message: "No HTTP response")
                    }
                    try self.checkStatus(httpResponse, provider: self.providerName)

                    var tools: [Int: AnthropicStreamingToolState] = [:]
                    var thinking: [Int: [String: Any]] = [:]
                    var toolCount = 0
                    var stopReason: String?
                    var inputTokens: Int?
                    var outputTokens: Int?
                    var cachedInputTokens: Int?
                    var reasoningTokens: Int?

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let raw = String(line.dropFirst(6))
                        guard let data = raw.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        switch object["type"] as? String {
                        case "message_start":
                            let message = object["message"] as? [String: Any]
                            let usage = message?["usage"] as? [String: Any]
                            inputTokens = usage?["input_tokens"] as? Int ?? inputTokens
                            cachedInputTokens = usage?["cache_read_input_tokens"] as? Int
                                ?? cachedInputTokens
                        case "content_block_start":
                            guard let index = object["index"] as? Int,
                                  let block = object["content_block"] as? [String: Any],
                                  let type = block["type"] as? String else { continue }
                            if type == "tool_use" {
                                let state = AnthropicStreamingToolState(
                                    eventIndex: toolCount,
                                    id: block["id"] as? String,
                                    name: block["name"] as? String
                                )
                                toolCount += 1
                                tools[index] = state
                                var event = AdapterStreamEvent(type: "tool_call_start")
                                event.index = state.eventIndex
                                event.id = state.id
                                event.name = state.name
                                continuation.yield(event)
                            } else if type == "thinking" || type == "redacted_thinking" {
                                thinking[index] = block
                            }
                        case "content_block_delta":
                            guard let delta = object["delta"] as? [String: Any],
                                  let deltaType = delta["type"] as? String else { continue }
                            let index = object["index"] as? Int
                            if deltaType == "text_delta",
                               let text = delta["text"] as? String,
                               !text.isEmpty {
                                var event = AdapterStreamEvent(type: "text_delta")
                                event.text = text
                                continuation.yield(event)
                            } else if deltaType == "thinking_delta",
                                      let index,
                                      let text = delta["thinking"] as? String,
                                      !text.isEmpty {
                                var block = thinking[index] ?? ["type": "thinking"]
                                block["thinking"] = (block["thinking"] as? String ?? "") + text
                                thinking[index] = block
                                var event = AdapterStreamEvent(type: "reasoning_summary_delta")
                                event.text = text
                                continuation.yield(event)
                            } else if deltaType == "signature_delta",
                                      let index,
                                      let signature = delta["signature"] as? String {
                                var block = thinking[index] ?? ["type": "thinking"]
                                block["signature"] = (block["signature"] as? String ?? "") + signature
                                thinking[index] = block
                            } else if deltaType == "input_json_delta",
                                      let index,
                                      let state = tools[index],
                                      let fragment = delta["partial_json"] as? String,
                                      !fragment.isEmpty {
                                state.arguments += fragment
                                var event = AdapterStreamEvent(type: "tool_call_delta")
                                event.index = state.eventIndex
                                event.argumentsDelta = fragment
                                continuation.yield(event)
                            }
                        case "content_block_stop":
                            guard let index = object["index"] as? Int,
                                  let state = tools.removeValue(forKey: index) else { continue }
                            var event = AdapterStreamEvent(type: "tool_call_end")
                            event.index = state.eventIndex
                            event.toolCall = ToolCall(
                                id: state.id ?? "call_\(state.eventIndex)",
                                name: state.name ?? "",
                                arguments: parseToolArguments(state.arguments)
                            )
                            continuation.yield(event)
                        case "message_delta":
                            let delta = object["delta"] as? [String: Any]
                            stopReason = delta?["stop_reason"] as? String ?? stopReason
                            let usage = object["usage"] as? [String: Any]
                            outputTokens = usage?["output_tokens"] as? Int ?? outputTokens
                            let outputDetails = usage?["output_tokens_details"] as? [String: Any]
                            reasoningTokens = outputDetails?["thinking_tokens"] as? Int
                                ?? reasoningTokens
                        default:
                            continue
                        }
                    }

                    if inputTokens != nil
                        || outputTokens != nil
                        || cachedInputTokens != nil
                        || reasoningTokens != nil {
                        var usage = AdapterStreamEvent(type: "usage")
                        usage.inputTokens = inputTokens
                        usage.outputTokens = outputTokens
                        usage.cachedInputTokens = cachedInputTokens
                        usage.reasoningTokens = reasoningTokens
                        continuation.yield(usage)
                    }
                    var finish = AdapterStreamEvent(type: "finish")
                    finish.finishReason = toolCount > 0
                        ? "tool_calls"
                        : self.mapFinishReason(stopReason)
                    finish.reasoning = Self.parseReasoning(
                        thinking.sorted { $0.key < $1.key }.map(\.value),
                        includeContinuation: toolCount > 0
                    )
                    continuation.yield(finish)
                    continuation.finish()
                } catch let error as PriestError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: PriestError.providerError(
                        self.providerName,
                        message: error.localizedDescription
                    ))
                }
            }
        }
    }

    // MARK: - Helpers

    func buildPayload(messages: [ChatMessage], config: PriestConfig, outputSpec: OutputSpec, options: AdapterCallOptions?) -> [String: Any] {
        // Extract system messages — Anthropic requires them as a top-level field
        var systemParts = messages.filter { $0.role == "system" }.map { $0.content }
        if let schema = outputSpec.jsonSchema,
           let schemaData = try? JSONSerialization.data(withJSONObject: JSONValue.object(schema).toFoundation(), options: .prettyPrinted),
           let schemaStr = String(data: schemaData, encoding: .utf8) {
            let instruction = "Respond with a valid JSON object that conforms to the following JSON Schema:\n\n<schema>\n\(schemaStr)\n</schema>\n\nReturn only the JSON object — no explanation, no markdown fences."
            systemParts.append(instruction)
        }
        let turns = Self.buildWireTurns(messages.filter { $0.role != "system" })

        var payload: [String: Any] = [
            "model": config.model,
            "messages": turns,
            "max_tokens": config.maxOutputTokens ?? AnthropicProvider.defaultMaxTokens,
        ]
        if !systemParts.isEmpty {
            payload["system"] = systemParts.joined(separator: "\n\n")
        }
        Self.applyReasoning(to: &payload, config: config)
        if let options, !options.tools.isEmpty {
            payload["tools"] = options.tools.map { tool -> [String: Any] in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.parameters.map { foundationObject(from: $0) }
                        ?? ["type": "object", "properties": [String: Any]()],
                ]
            }
            if let choice = options.toolChoice {
                switch choice {
                case .auto: payload["tool_choice"] = ["type": "auto"]
                case .none: payload["tool_choice"] = ["type": "none"]
                case .required: payload["tool_choice"] = ["type": "any"]
                case let .tool(name): payload["tool_choice"] = ["type": "tool", "name": name]
                }
            }
        }
        for (k, v) in config.providerOptions {
            payload[k] = v.toFoundation()
        }
        return payload
    }

    /// Translate messages to Anthropic wire format. Tool results merge into a
    /// user message of tool_result blocks (Anthropic requires alternating
    /// roles); assistant tool calls become tool_use content blocks.
    static func buildWireTurns(_ messages: [ChatMessage]) -> [[String: Any]] {
        var turns: [[String: Any]] = []
        var pendingToolResults: [[String: Any]] = []

        func flushToolResults() {
            if !pendingToolResults.isEmpty {
                turns.append(["role": "user", "content": pendingToolResults])
                pendingToolResults = []
            }
        }

        for m in messages {
            if m.role == "tool" {
                pendingToolResults.append([
                    "type": "tool_result",
                    "tool_use_id": m.toolCallId ?? "",
                    "content": m.content,
                ])
                continue
            }
            flushToolResults()
            if m.role == "assistant", let calls = m.toolCalls, !calls.isEmpty {
                var blocks: [[String: Any]] = []
                for state in m.reasoning?.continuation ?? [] where state.format == reasoningFormat {
                    if let block = state.value.toFoundation() as? [String: Any] {
                        blocks.append(block)
                    }
                }
                if !m.content.isEmpty {
                    blocks.append(["type": "text", "text": m.content])
                }
                for call in calls {
                    blocks.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": foundationObject(from: call.arguments),
                    ])
                }
                turns.append(["role": "assistant", "content": blocks])
                continue
            }
            turns.append(["role": m.role, "content": m.content])
        }
        flushToolResults()
        return turns
    }

    private static func parseToolUseBlocks(_ content: [[String: Any]]) -> [ToolCall]? {
        var calls: [ToolCall] = []
        for (i, block) in content.enumerated() {
            guard block["type"] as? String == "tool_use",
                  let name = block["name"] as? String, !name.isEmpty else { continue }
            calls.append(ToolCall(
                id: (block["id"] as? String) ?? "call_\(i)",
                name: name,
                arguments: jsonValueObject(fromFoundation: block["input"])
            ))
        }
        return calls.isEmpty ? nil : calls
    }

    private static func parseReasoning(
        _ content: [[String: Any]],
        includeContinuation: Bool
    ) -> ReasoningInfo? {
        let thinking = content.filter {
            let type = $0["type"] as? String
            return type == "thinking" || type == "redacted_thinking"
        }
        let summaries = thinking.compactMap { block -> String? in
            guard block["type"] as? String == "thinking",
                  let summary = block["thinking"] as? String,
                  !summary.isEmpty else { return nil }
            return summary
        }
        let continuation = includeContinuation ? thinking.compactMap { block -> OpaqueReasoningState? in
            guard let value = jsonValue(fromFoundation: block) else { return nil }
            return OpaqueReasoningState(format: reasoningFormat, value: value)
        } : []
        guard !summaries.isEmpty || !continuation.isEmpty else { return nil }
        return ReasoningInfo(
            summary: summaries.isEmpty ? nil : summaries.joined(separator: "\n\n"),
            continuation: continuation.isEmpty ? nil : continuation
        )
    }

    private static func applyReasoning(to payload: inout [String: Any], config: PriestConfig) {
        guard let reasoning = config.reasoning else { return }
        let disabled = reasoning.enabled == false || reasoning.effort == ReasoningEffort.none
        let needsThinking = reasoning.enabled == true || reasoning.effort != nil || reasoning.summary != nil

        if disabled {
            payload["thinking"] = ["type": "disabled"]
        } else if needsThinking {
            var thinking: [String: Any] = ["type": "adaptive"]
            if reasoning.summary == .auto { thinking["display"] = "summarized" }
            if reasoning.summary == ReasoningSummaryMode.none { thinking["display"] = "omitted" }
            payload["thinking"] = thinking
        }
        if let effort = reasoning.effort, effort != .none {
            payload["output_config"] = ["effort": effort.rawValue]
        }
    }

    private func buildRequest(path: String, payload: [String: Any], timeout: Double) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(AnthropicProvider.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return req
    }

    private func post(path: String, payload: [String: Any], timeout: Double) async throws -> Data {
        let request = try buildRequest(path: path, payload: payload, timeout: timeout)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PriestError.providerError(providerName, message: "No HTTP response")
            }
            try checkStatus(httpResponse, provider: providerName)
            return data
        } catch let e as PriestError { throw e }
        catch let urlError as URLError where urlError.code == .timedOut {
            throw PriestError.providerTimeout(providerName, timeout: timeout)
        } catch {
            throw PriestError.providerError(providerName, message: error.localizedDescription)
        }
    }

    private func checkStatus(_ response: HTTPURLResponse, provider: String) throws {
        if response.statusCode == 429 { throw PriestError.providerRateLimited(provider) }
        guard (200..<300).contains(response.statusCode) else {
            throw PriestError.providerError(provider, message: "HTTP \(response.statusCode)")
        }
    }

    private func parseJSON(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PriestError.providerError(providerName, message: "Invalid JSON response")
        }
        return obj
    }

    private func mapFinishReason(_ reason: String?) -> String? {
        guard let reason else { return nil }
        switch reason {
        case "end_turn", "stop_sequence": return "stop"
        case "max_tokens":                return "length"
        case "tool_use":                  return "tool_calls"
        default:                          return "unknown"
        }
    }
}

private final class AnthropicStreamingToolState {
    let eventIndex: Int
    let id: String?
    let name: String?
    var arguments = ""

    init(eventIndex: Int, id: String?, name: String?) {
        self.eventIndex = eventIndex
        self.id = id
        self.name = name
    }
}
