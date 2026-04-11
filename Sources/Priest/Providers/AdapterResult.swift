/// Raw result from a provider adapter before mapping to PriestResponse.
public struct AdapterResult: Sendable {
    public let text: String?
    public let finishReason: String?
    public let inputTokens: Int?
    public let outputTokens: Int?

    public init(text: String?, finishReason: String? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.text = text
        self.finishReason = finishReason
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}
