import Foundation

// Tool calling types (spec 2.4.0, behavior/tool-calling.md).
//
// The library transports tool definitions and calls; it never executes
// tools — execution is the caller's responsibility.

/// A tool the model may call.
public struct ToolDefinition: Sendable, Equatable {
    public let name: String
    public let description: String
    /// JSON Schema object describing the tool's parameters.
    public let parameters: [String: JSONValue]?

    public init(name: String, description: String = "", parameters: [String: JSONValue]? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Tool selection behavior. Only meaningful when tools are provided.
public enum ToolChoice: Sendable, Equatable {
    case auto
    case none
    case required
    case tool(name: String)
}

/// A single tool call requested by the model. Providers that do not assign
/// call ids (Ollama) get synthesized ids "call_0", "call_1", ... in order.
/// Arguments are always a parsed JSON object; unparseable provider JSON
/// becomes an empty object.
public struct ToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: [String: JSONValue]

    public init(id: String, name: String, arguments: [String: JSONValue] = [:]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// One entry in the turn-local tool loop history. Callers replay the full
/// exchange on each loop iteration via `PriestRequest.toolExchange`.
/// Exchange turns are never persisted in sessions.
public enum ToolExchangeTurn: Sendable, Equatable {
    case assistant(text: String?, toolCalls: [ToolCall], reasoning: ReasoningInfo? = nil)
    case toolResult(toolCallId: String, name: String, content: String, isError: Bool = false)
}

/// Per spec, unparseable or non-object argument JSON becomes an empty object.
public func parseToolArguments(_ raw: String) -> [String: JSONValue] {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return [:] }
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
          case let .object(map) = value else { return [:] }
    return map
}
