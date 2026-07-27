import Foundation

/// Provider adapter for Ollama's /api/chat endpoint.
///
/// Supports native streaming via NDJSON (URLSession.bytes).
/// See `behavior/providers.md` for the full translation specification.
public final class OllamaProvider: ProviderAdapter {
    public let providerName = "ollama"
    private let baseURL: URL

    public init(baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.baseURL = baseURL
    }

    // MARK: - complete

    public func complete(
        messages: [ChatMessage],
        config: PriestConfig,
        outputSpec: OutputSpec,
        options: AdapterCallOptions? = nil
    ) async throws -> AdapterResult {
        try validateReasoning(config)
        let payload = buildPayload(messages: messages, config: config, outputSpec: outputSpec, options: options, stream: false)
        let data = try await post(path: "/api/chat", payload: payload, timeout: config.timeoutSeconds)
        let json = try parseJSON(data)
        let message = json["message"] as? [String: Any]
        let text = message?["content"] as? String
        let toolCalls = Self.parseToolCalls(message?["tool_calls"] as? [[String: Any]])
        let doneReason = json["done_reason"] as? String
        return AdapterResult(
            text: text,
            finishReason: toolCalls != nil ? "tool_calls" : mapFinishReason(doneReason),
            inputTokens: json["prompt_eval_count"] as? Int,
            outputTokens: json["eval_count"] as? Int,
            toolCalls: toolCalls
        )
    }

    // MARK: - stream

    public func stream(
        messages: [ChatMessage],
        config: PriestConfig,
        outputSpec: OutputSpec,
        options: AdapterCallOptions? = nil
    ) -> AsyncThrowingStream<String, Error> {
        let payload = buildPayload(messages: messages, config: config, outputSpec: outputSpec, options: options, stream: true)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try self.validateReasoning(config)
                    let request = try self.buildRequest(path: "/api/chat", payload: payload, timeout: config.timeoutSeconds)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw PriestError.providerError(self.providerName, message: "No HTTP response")
                    }
                    try self.checkStatus(httpResponse, provider: self.providerName)
                    for try await line in bytes.lines {
                        guard !line.isEmpty else { continue }
                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let content = (obj["message"] as? [String: Any])?["content"] as? String, !content.isEmpty {
                            continuation.yield(content)
                        }
                        if obj["done"] as? Bool == true { break }
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

    // MARK: - Helpers

    func buildPayload(messages: [ChatMessage], config: PriestConfig, outputSpec: OutputSpec, options: AdapterCallOptions?, stream: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "model": config.model,
            "messages": Self.buildWireMessages(messages),
            "stream": stream,
        ]
        if let options, !options.tools.isEmpty {
            // Ollama accepts OpenAI-shaped tools; it has no tool_choice parameter.
            payload["tools"] = options.tools.map { tool -> [String: Any] in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters.map { foundationObject(from: $0) } ?? [:],
                    ] as [String: Any],
                ]
            }
        }
        if let n = config.maxOutputTokens {
            payload["options"] = ["num_predict": n]
        }
        if let reasoning = config.reasoning {
            if reasoning.enabled == false || reasoning.effort == ReasoningEffort.none {
                payload["think"] = false
            } else if let effort = reasoning.effort,
                      effort != .minimal,
                      effort != .xhigh {
                payload["think"] = effort.rawValue
            } else if reasoning.enabled == true, reasoning.effort == nil {
                payload["think"] = true
            }
        }
        if let schema = outputSpec.jsonSchema {
            payload["format"] = JSONValue.object(schema).toFoundation()
        } else if outputSpec.providerFormat == .json {
            payload["format"] = "json"
        }
        for (k, v) in config.providerOptions {
            payload[k] = v.toFoundation()
        }
        return payload
    }

    private func validateReasoning(_ config: PriestConfig) throws {
        guard let effort = config.reasoning?.effort,
              effort == .minimal || effort == .xhigh else { return }
        throw PriestError(
            code: .requestInvalid,
            message: "Ollama does not define the reasoning effort '\(effort.rawValue)'",
            details: ["provider": providerName, "effort": effort.rawValue]
        )
    }

    private func buildRequest(path: String, payload: [String: Any], timeout: Double) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
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

    private static func buildWireMessages(_ messages: [ChatMessage]) -> [[String: Any]] {
        messages.map { m -> [String: Any] in
            if m.role == "tool" {
                // Ollama correlates tool results by tool_name, not call id.
                return ["role": "tool", "content": m.content, "tool_name": m.name ?? ""]
            }
            if m.role == "assistant", let calls = m.toolCalls, !calls.isEmpty {
                // Synthesized call ids are dropped on the wire.
                return [
                    "role": "assistant",
                    "content": m.content,
                    "tool_calls": calls.map { ["function": ["name": $0.name, "arguments": foundationObject(from: $0.arguments)] as [String: Any]] },
                ]
            }
            return ["role": m.role, "content": m.content]
        }
    }

    /// Parse Ollama wire tool calls, synthesizing ids "call_N" in order.
    private static func parseToolCalls(_ raw: [[String: Any]]?) -> [ToolCall]? {
        guard let raw, !raw.isEmpty else { return nil }
        var calls: [ToolCall] = []
        for item in raw {
            guard let function = item["function"] as? [String: Any],
                  let name = function["name"] as? String, !name.isEmpty else { continue }
            calls.append(ToolCall(
                id: "call_\(calls.count)",
                name: name,
                arguments: jsonValueObject(fromFoundation: function["arguments"])
            ))
        }
        return calls.isEmpty ? nil : calls
    }

    private func mapFinishReason(_ reason: String?) -> String? {
        guard let reason else { return nil }
        switch reason {
        case "stop", "load": return "stop"
        case "length":       return "length"
        default:             return "unknown"
        }
    }
}
