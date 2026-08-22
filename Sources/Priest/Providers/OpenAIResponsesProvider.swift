import Foundation

/// First-class provider for OpenAI's Responses endpoint.
///
/// This adapter is separate from `OpenAICompatProvider` and does not change
/// Chat Completions behavior.
public final class OpenAIResponsesProvider: ProviderAdapter, @unchecked Sendable {
    public let providerName = "openai-responses"

    private static let reasoningFormat = "openai.responses.reasoning.v1"

    private let baseURL: URL
    private let exactURL: URL?
    private let apiKey: String?
    private let headers: [String: String]
    private let session: URLSession

    public init(
        baseURL: URL = URL(string: "https://api.openai.com")!,
        apiKey: String? = nil,
        url: URL? = nil,
        headers: [String: String] = [:],
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.exactURL = url
        self.apiKey = apiKey
        self.headers = headers
        self.session = session
    }

    public func complete(
        messages: [ChatMessage],
        config: PriestConfig,
        outputSpec: OutputSpec,
        options: AdapterCallOptions? = nil
    ) async throws -> AdapterResult {
        let payload = buildPayload(
            messages: messages,
            config: config,
            outputSpec: outputSpec,
            options: options,
            stream: false
        )
        let request = try buildRequest(payload: payload, timeout: config.timeoutSeconds)
        do {
            let (data, response) = try await session.data(for: request)
            try checkResponse(response, data: data)
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PriestError.providerError(providerName, message: "Invalid JSON response")
            }
            return try Self.parseResponse(value)
        } catch is CancellationError {
            throw PriestError(code: .requestAborted, message: "Request to provider '\(providerName)' was aborted", details: ["provider": providerName])
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw PriestError(code: .requestAborted, message: "Request to provider '\(providerName)' was aborted", details: ["provider": providerName])
        } catch let error as URLError where error.code == .timedOut {
            throw PriestError.providerTimeout(providerName, timeout: config.timeoutSeconds)
        } catch let error as PriestError {
            throw error
        } catch {
            throw PriestError.providerError(providerName, message: error.localizedDescription)
        }
    }

    public func stream(
        messages: [ChatMessage],
        config: PriestConfig,
        outputSpec: OutputSpec,
        options: AdapterCallOptions? = nil
    ) -> AsyncThrowingStream<String, Error> {
        let events = streamEvents(
            messages: messages,
            config: config,
            outputSpec: outputSpec,
            options: options
        )
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await event in events where event.type == "text_delta" {
                        if let text = event.text { continuation.yield(text) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
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
        let payload = buildPayload(
            messages: messages,
            config: config,
            outputSpec: outputSpec,
            options: options,
            stream: true
        )
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = try self.buildRequest(payload: payload, timeout: config.timeoutSeconds)
                    let (bytes, response) = try await self.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw PriestError.providerError(self.providerName, message: "No HTTP response")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw PriestError.providerError(
                            self.providerName,
                            message: "HTTP \(http.statusCode): \(body)"
                        )
                    }

                    let parser = ResponsesStreamParser()
                    var dataLines: [String] = []

                    func flushFrame() throws {
                        guard !dataLines.isEmpty else { return }
                        let data = dataLines.joined(separator: "\n")
                        dataLines.removeAll(keepingCapacity: true)
                        guard data != "[DONE]" else { return }
                        for event in try parser.process(data) {
                            continuation.yield(event)
                        }
                    }

                    for try await rawLine in bytes.lines {
                        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
                        if line.isEmpty {
                            try flushFrame()
                        } else if line.hasPrefix("data:") {
                            dataLines.append(String(line.dropFirst(5)).trimmingPrefixSpace())
                        }
                    }
                    try flushFrame()
                    for event in parser.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: PriestError(
                        code: .requestAborted,
                        message: "Request to provider '\(self.providerName)' was aborted",
                        details: ["provider": self.providerName]
                    ))
                } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
                    continuation.finish(throwing: PriestError(
                        code: .requestAborted,
                        message: "Request to provider '\(self.providerName)' was aborted",
                        details: ["provider": self.providerName]
                    ))
                } catch let error as URLError where error.code == .timedOut {
                    continuation.finish(throwing: PriestError.providerTimeout(
                        self.providerName,
                        timeout: config.timeoutSeconds
                    ))
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

    // MARK: - Wire mapping

    func buildPayload(
        messages: [ChatMessage],
        config: PriestConfig,
        outputSpec: OutputSpec,
        options: AdapterCallOptions?,
        stream: Bool
    ) -> [String: Any] {
        var payload: [String: Any] = ["store": false]

        if let maxOutputTokens = config.maxOutputTokens {
            payload["max_output_tokens"] = maxOutputTokens
        }
        if let reasoning = Self.openAIReasoning(config) {
            payload["reasoning"] = reasoning
        }
        if let schema = outputSpec.jsonSchema {
            payload["text"] = [
                "format": [
                    "type": "json_schema",
                    "name": outputSpec.jsonSchemaName,
                    "schema": JSONValue.object(schema).toFoundation(),
                    "strict": outputSpec.jsonSchemaStrict,
                ] as [String: Any],
            ]
        } else if outputSpec.providerFormat == .json {
            payload["text"] = ["format": ["type": "json_object"]]
        }
        if let options, !options.tools.isEmpty {
            payload["tools"] = options.tools.map { tool -> [String: Any] in
                [
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parameters.map(foundationObject(from:)) ?? [:],
                ]
            }
            if let choice = options.toolChoice {
                switch choice {
                case .auto: payload["tool_choice"] = "auto"
                case .none: payload["tool_choice"] = "none"
                case .required: payload["tool_choice"] = "required"
                case let .tool(name): payload["tool_choice"] = ["type": "function", "name": name]
                }
            }
        }
        for (key, value) in config.providerOptions {
            payload[key] = value.toFoundation()
        }

        // Adapter-owned operation invariants override provider options.
        payload["model"] = config.model
        payload["input"] = Self.responsesInput(messages)
        payload["stream"] = stream
        return payload
    }

    static func parseResponse(_ data: [String: Any]) throws -> AdapterResult {
        let status = data["status"] as? String
        if status == "failed" || status == "cancelled" || data["error"] != nil {
            throw responseError(data)
        }

        let output = data["output"] as? [[String: Any]] ?? []
        var textParts: [String] = []
        var toolCalls: [ToolCall] = []
        var summaries: [String] = []
        var states: [OpaqueReasoningState] = []

        for item in output {
            switch item["type"] as? String {
            case "message":
                let content = item["content"] as? [[String: Any]] ?? []
                textParts.append(contentsOf: content.compactMap { part in
                    guard part["type"] as? String == "output_text" else { return nil }
                    return part["text"] as? String
                })
            case "function_call":
                guard let name = item["name"] as? String, !name.isEmpty else { continue }
                toolCalls.append(ToolCall(
                    id: (item["call_id"] as? String)
                        ?? (item["id"] as? String)
                        ?? "call_\(toolCalls.count)",
                    name: name,
                    arguments: parseToolArguments(item["arguments"] as? String ?? "")
                ))
            case "reasoning":
                let summary = item["summary"] as? [[String: Any]] ?? []
                summaries.append(contentsOf: summary.compactMap { part in
                    guard part["type"] as? String == "summary_text",
                          let text = part["text"] as? String,
                          !text.isEmpty else { return nil }
                    return text
                })
                if let state = safeReasoningState(item) { states.append(state) }
            default:
                continue
            }
        }

        let hasTools = !toolCalls.isEmpty
        let continuation = hasTools && !states.isEmpty ? states : nil
        let reasoning = summaries.isEmpty && continuation == nil ? nil : ReasoningInfo(
            summary: summaries.isEmpty ? nil : summaries.joined(separator: "\n\n"),
            continuation: continuation
        )
        let usage = data["usage"] as? [String: Any]
        let inputDetails = usage?["input_tokens_details"] as? [String: Any]
        let outputDetails = usage?["output_tokens_details"] as? [String: Any]

        return AdapterResult(
            text: textParts.joined(),
            finishReason: responseFinish(data, hasTools: hasTools),
            inputTokens: usage?["input_tokens"] as? Int,
            outputTokens: usage?["output_tokens"] as? Int,
            cachedInputTokens: inputDetails?["cached_tokens"] as? Int,
            toolCalls: hasTools ? toolCalls : nil,
            reasoningTokens: outputDetails?["reasoning_tokens"] as? Int,
            reasoning: reasoning
        )
    }

    static func parseSSE(_ body: String) throws -> [AdapterStreamEvent] {
        let parser = ResponsesStreamParser()
        var events: [AdapterStreamEvent] = []
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
        for frame in normalized.components(separatedBy: "\n\n") {
            let data = frame
                .split(separator: "\n", omittingEmptySubsequences: false)
                .compactMap { line -> String? in
                    guard line.hasPrefix("data:") else { return nil }
                    return String(line.dropFirst(5)).trimmingPrefixSpace()
                }
                .joined(separator: "\n")
            guard !data.isEmpty, data != "[DONE]" else { continue }
            events.append(contentsOf: try parser.process(data))
        }
        events.append(contentsOf: parser.finish())
        return events
    }

    private static func responsesInput(_ messages: [ChatMessage]) -> [[String: Any]] {
        var input: [[String: Any]] = []
        for message in messages {
            if message.role == "tool" {
                input.append([
                    "type": "function_call_output",
                    "call_id": message.toolCallId ?? "",
                    "output": message.content,
                ])
                continue
            }
            if message.role == "assistant", let calls = message.toolCalls, !calls.isEmpty {
                for state in message.reasoning?.continuation ?? []
                    where state.format == reasoningFormat {
                    if let value = state.value.toFoundation() as? [String: Any] {
                        input.append(value)
                    }
                }
                for call in calls {
                    input.append([
                        "type": "function_call",
                        "call_id": call.id,
                        "name": call.name,
                        "arguments": argumentsJSONString(call.arguments),
                    ])
                }
                continue
            }
            let textType = message.role == "assistant" ? "output_text" : "input_text"
            input.append([
                "role": message.role,
                "content": [["type": textType, "text": message.content]],
            ])
        }
        return input
    }

    private static func openAIReasoning(_ config: PriestConfig) -> [String: Any]? {
        guard let requested = config.reasoning else { return nil }
        var reasoning: [String: Any] = [:]
        if let effort = requested.effort {
            reasoning["effort"] = effort.rawValue
        } else if requested.enabled == false {
            reasoning["effort"] = "none"
        }
        if requested.summary == .auto {
            reasoning["summary"] = "auto"
        }
        return reasoning.isEmpty ? nil : reasoning
    }

    private static func safeReasoningState(
        _ item: [String: Any]
    ) -> OpaqueReasoningState? {
        if let content = item["content"] as? [Any], !content.isEmpty { return nil }
        guard item["encrypted_content"] != nil || item["id"] != nil else { return nil }

        var value: [String: Any] = ["type": "reasoning"]
        for key in ["id", "status", "summary", "encrypted_content"] {
            if let field = item[key] { value[key] = field }
        }
        guard let json = jsonValue(fromFoundation: value) else { return nil }
        return OpaqueReasoningState(format: reasoningFormat, value: json)
    }

    private static func responseFinish(
        _ data: [String: Any],
        hasTools: Bool
    ) -> String {
        if hasTools { return "tool_calls" }
        if data["status"] as? String == "incomplete" {
            let details = data["incomplete_details"] as? [String: Any]
            switch details?["reason"] as? String {
            case "max_output_tokens": return "length"
            case "content_filter": return "content_filter"
            default: return "unknown"
            }
        }
        let status = data["status"] as? String
        return status == nil || status == "completed" ? "stop" : "unknown"
    }

    fileprivate static func responseError(_ data: [String: Any]) -> PriestError {
        let error = data["error"] as? [String: Any]
        let prefix = (error?["code"] as? String).map { "\($0): " } ?? ""
        let message = (error?["message"] as? String)
            ?? "response status \((data["status"] as? String) ?? "failed")"
        return PriestError.providerError("openai-responses", message: prefix + message)
    }

    // MARK: - HTTP

    private func buildRequest(payload: [String: Any], timeout: Double) throws -> URLRequest {
        let url = exactURL ?? baseURL.appendingPathComponent("/v1/responses")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PriestError.providerError(providerName, message: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PriestError.providerError(
                providerName,
                message: "HTTP \(http.statusCode): \(body)"
            )
        }
    }
}

private final class ResponsesStreamParser {
    private final class Partial {
        let eventIndex: Int
        var callID: String?
        var name: String?
        var arguments: String
        var ended = false

        init(eventIndex: Int, item: [String: Any]? = nil) {
            self.eventIndex = eventIndex
            self.callID = item?["call_id"] as? String
            self.name = item?["name"] as? String
            self.arguments = item?["arguments"] as? String ?? ""
        }
    }

    private var partials: [Int: Partial] = [:]
    private var emittedCallIDs: Set<String> = []
    private var nextEventIndex = 0
    private var terminalSeen = false

    func process(_ data: String) throws -> [AdapterStreamEvent] {
        guard let bytes = data.data(using: .utf8),
              let event = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else { return [] }
        var events: [AdapterStreamEvent] = []

        switch event["type"] as? String {
        case "response.output_text.delta":
            if let text = event["delta"] as? String, !text.isEmpty {
                var output = AdapterStreamEvent(type: "text_delta")
                output.text = text
                events.append(output)
            }
        case "response.reasoning_summary_text.delta":
            if let text = event["delta"] as? String, !text.isEmpty {
                var output = AdapterStreamEvent(type: "reasoning_summary_delta")
                output.text = text
                events.append(output)
            }
        case "response.output_item.added":
            guard let item = event["item"] as? [String: Any],
                  item["type"] as? String == "function_call" else { break }
            let outputIndex = event["output_index"] as? Int ?? partials.count
            let partial = ensurePartial(outputIndex, item: item)
            var output = AdapterStreamEvent(type: "tool_call_start")
            output.index = partial.eventIndex
            output.id = partial.callID
            output.name = partial.name
            events.append(output)
        case "response.function_call_arguments.delta":
            let partial = ensurePartial(event["output_index"] as? Int ?? 0)
            if let delta = event["delta"] as? String, !delta.isEmpty {
                partial.arguments += delta
                var output = AdapterStreamEvent(type: "tool_call_delta")
                output.index = partial.eventIndex
                output.argumentsDelta = delta
                events.append(output)
            }
        case "response.function_call_arguments.done":
            let partial = ensurePartial(event["output_index"] as? Int ?? 0)
            if let arguments = event["arguments"] as? String { partial.arguments = arguments }
            if let name = event["name"] as? String { partial.name = name }
            if let output = finishPartial(partial) { events.append(output) }
        case "response.output_item.done":
            guard let item = event["item"] as? [String: Any],
                  item["type"] as? String == "function_call" else { break }
            let partial = ensurePartial(
                event["output_index"] as? Int ?? 0,
                item: item
            )
            if let output = finishPartial(partial) { events.append(output) }
        case "response.completed":
            terminalSeen = true
            let response = event["response"] as? [String: Any] ?? [:]
            let parsed = try OpenAIResponsesProvider.parseResponse(response)
            events.append(contentsOf: finishPartials())
            for call in parsed.toolCalls ?? [] where !emittedCallIDs.contains(call.id) {
                emittedCallIDs.insert(call.id)
                var start = AdapterStreamEvent(type: "tool_call_start")
                start.index = nextEventIndex
                start.id = call.id
                start.name = call.name
                events.append(start)
                var end = AdapterStreamEvent(type: "tool_call_end")
                end.index = nextEventIndex
                end.toolCall = call
                events.append(end)
                nextEventIndex += 1
            }
            if parsed.inputTokens != nil
                || parsed.outputTokens != nil
                || parsed.cachedInputTokens != nil
                || parsed.reasoningTokens != nil {
                var usage = AdapterStreamEvent(type: "usage")
                usage.inputTokens = parsed.inputTokens
                usage.outputTokens = parsed.outputTokens
                usage.cachedInputTokens = parsed.cachedInputTokens
                usage.reasoningTokens = parsed.reasoningTokens
                events.append(usage)
            }
            var finish = AdapterStreamEvent(type: "finish")
            finish.finishReason = parsed.finishReason
            finish.reasoning = parsed.reasoning
            events.append(finish)
        case "response.failed", "response.cancelled":
            terminalSeen = true
            throw OpenAIResponsesProvider.responseError(
                event["response"] as? [String: Any] ?? [:]
            )
        case "error":
            terminalSeen = true
            throw PriestError.providerError(
                "openai-responses",
                message: (event["message"] as? String) ?? String(describing: event)
            )
        default:
            break
        }
        return events
    }

    func finish() -> [AdapterStreamEvent] {
        var events = finishPartials()
        if !terminalSeen {
            var finish = AdapterStreamEvent(type: "finish")
            finish.finishReason = partials.isEmpty ? "stop" : "tool_calls"
            events.append(finish)
        }
        return events
    }

    private func ensurePartial(
        _ outputIndex: Int,
        item: [String: Any]? = nil
    ) -> Partial {
        if let partial = partials[outputIndex] {
            if let callID = item?["call_id"] as? String { partial.callID = callID }
            if let name = item?["name"] as? String { partial.name = name }
            if let arguments = item?["arguments"] as? String { partial.arguments = arguments }
            return partial
        }
        let partial = Partial(eventIndex: nextEventIndex, item: item)
        nextEventIndex += 1
        partials[outputIndex] = partial
        return partial
    }

    private func finishPartial(_ partial: Partial) -> AdapterStreamEvent? {
        guard !partial.ended else { return nil }
        partial.ended = true
        let id = partial.callID ?? "call_\(partial.eventIndex)"
        emittedCallIDs.insert(id)
        var event = AdapterStreamEvent(type: "tool_call_end")
        event.index = partial.eventIndex
        event.toolCall = ToolCall(
            id: id,
            name: partial.name ?? "",
            arguments: parseToolArguments(partial.arguments)
        )
        return event
    }

    private func finishPartials() -> [AdapterStreamEvent] {
        partials.values
            .sorted { $0.eventIndex < $1.eventIndex }
            .compactMap(finishPartial)
    }
}

private extension String {
    func trimmingPrefixSpace() -> String {
        hasPrefix(" ") ? String(dropFirst()) : self
    }
}
