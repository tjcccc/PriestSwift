/// One message in the provider conversation. `toolCalls` is set on assistant
/// turns that requested tools; `toolCallId`/`name` are set on tool-result
/// turns (spec 2.4.0).
public struct ChatMessage: Sendable {
    public var role: String
    public var content: String
    public var toolCalls: [ToolCall]?
    public var toolCallId: String?
    public var name: String?

    public init(
        role: String,
        content: String,
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil,
        name: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.name = name
    }

    /// Back-compat with the previous `[[String: String]]` message shape.
    public subscript(key: String) -> String? {
        switch key {
        case "role": return role
        case "content": return content
        default: return nil
        }
    }
}

/// Per-call options threaded from the engine into adapters (spec 2.4.0).
public struct AdapterCallOptions: Sendable {
    public let tools: [ToolDefinition]
    public let toolChoice: ToolChoice?

    public init(tools: [ToolDefinition], toolChoice: ToolChoice? = nil) {
        self.tools = tools
        self.toolChoice = toolChoice
    }
}

/// One structured streaming event from an adapter (spec 2.4.0). `type` is one
/// of: text_delta, tool_call_start, tool_call_delta, tool_call_end, usage,
/// finish. Only the fields relevant to the type are populated.
public struct AdapterStreamEvent: Sendable {
    public let type: String
    public var text: String?
    public var index: Int?
    public var id: String?
    public var name: String?
    public var argumentsDelta: String?
    public var toolCall: ToolCall?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var finishReason: String?

    public init(type: String) {
        self.type = type
    }
}

/// Protocol for provider adapters.
///
/// Adapters are thin translators: messages in, AdapterResult out.
/// They do not inspect profile content, call back into the engine,
/// or perform any business logic beyond sending the request and
/// normalizing the response.
///
/// Cancellation: Swift maps the spec's cancellation concept to native Task
/// cancellation — adapters must respect `Task.isCancelled` / URLSession
/// cancellation.
public protocol ProviderAdapter: Sendable {
    var providerName: String { get }

    func complete(
        messages: [ChatMessage],
        config: PriestConfig,
        outputSpec: OutputSpec,
        options: AdapterCallOptions?
    ) async throws -> AdapterResult

    func stream(
        messages: [ChatMessage],
        config: PriestConfig,
        outputSpec: OutputSpec,
        options: AdapterCallOptions?
    ) -> AsyncThrowingStream<String, Error>
}

// MARK: - Default implementations

public extension ProviderAdapter {
    /// Default stream: calls complete() and yields the full text as a single chunk.
    /// Adapters with native streaming support should override this.
    func stream(
        messages: [ChatMessage],
        config: PriestConfig,
        outputSpec: OutputSpec,
        options: AdapterCallOptions?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await complete(messages: messages, config: config, outputSpec: outputSpec, options: options)
                    if let text = result.text, !text.isEmpty {
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Yield structured streaming events (spec 2.4.0). The default
    /// implementation wraps stream(): each text chunk becomes a text_delta
    /// and a final finish event is synthesized.
    func streamEvents(
        messages: [ChatMessage],
        config: PriestConfig,
        outputSpec: OutputSpec,
        options: AdapterCallOptions?
    ) -> AsyncThrowingStream<AdapterStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await chunk in stream(messages: messages, config: config, outputSpec: outputSpec, options: options) {
                        var event = AdapterStreamEvent(type: "text_delta")
                        event.text = chunk
                        continuation.yield(event)
                    }
                    var finish = AdapterStreamEvent(type: "finish")
                    finish.finishReason = "stop"
                    continuation.yield(finish)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
