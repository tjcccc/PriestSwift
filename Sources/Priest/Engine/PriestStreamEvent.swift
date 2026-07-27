/// Engine-level structured streaming event (spec 2.4.0). `type` is one of:
/// text_delta, tool_call_start, tool_call_delta, tool_call_end, usage, done.
/// The terminal event is always "done" carrying the full PriestResponse.
public struct PriestStreamEvent: Sendable {
    public let type: String
    public var text: String?
    public var index: Int?
    public var id: String?
    public var name: String?
    public var argumentsDelta: String?
    public var toolCall: ToolCall?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedInputTokens: Int?
    public var reasoningTokens: Int?
    public var response: PriestResponse?

    public init(type: String) {
        self.type = type
    }
}
