/// Raw result from a provider adapter before mapping to PriestResponse.
public struct AdapterResult: Sendable {
    public let text: String?
    public let finishReason: String?
    public let inputTokens: Int?
    public let outputTokens: Int?
    /// Prompt-cache hit count (spec 2.5.0). Nil when the provider omits it.
    public let cachedInputTokens: Int?
    /// Provider-reported reasoning tokens. A subset of output tokens.
    public let reasoningTokens: Int?
    /// Tool calls requested by the model (spec 2.4.0). Nil when there are none.
    public let toolCalls: [ToolCall]?
    /// Safe provider-supplied reasoning information.
    public let reasoning: ReasoningInfo?

    public init(
        text: String?,
        finishReason: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        toolCalls: [ToolCall]? = nil,
        reasoningTokens: Int? = nil,
        reasoning: ReasoningInfo? = nil
    ) {
        self.text = text
        self.finishReason = finishReason
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.toolCalls = toolCalls
        self.reasoningTokens = reasoningTokens
        self.reasoning = reasoning
    }
}
