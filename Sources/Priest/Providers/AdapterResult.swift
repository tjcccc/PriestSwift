/// Raw result from a provider adapter before mapping to PriestResponse.
public struct AdapterResult: Sendable {
    public let text: String?
    public let finishReason: String?
    public let inputTokens: Int?
    public let outputTokens: Int?
    /// Tool calls requested by the model (spec 2.4.0). Nil when there are none.
    public let toolCalls: [ToolCall]?

    public init(
        text: String?,
        finishReason: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        toolCalls: [ToolCall]? = nil
    ) {
        self.text = text
        self.finishReason = finishReason
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.toolCalls = toolCalls
    }
}
