import Foundation

/// Provider and model configuration for a single priest run.
public struct PriestConfig: Sendable {
    /// Registered provider name. Must match a key in the engine's adapter registry.
    public var provider: String
    /// Model identifier passed directly to the provider.
    public var model: String
    /// Request timeout in seconds. Defaults to 60.0.
    public var timeoutSeconds: Double
    /// Maximum tokens to generate. Omitted from provider request if nil.
    public var maxOutputTokens: Int?
    /// Advisory cost ceiling in USD. The engine does NOT enforce this.
    public var costLimit: Double?
    /// Budget for the assembled system prompt in characters. Triggers tail-trim of memory entries when exceeded.
    public var maxSystemChars: Int?
    /// Conversation compaction budget (spec 2.5.0). When set, a chat turn whose
    /// reported input usage crosses 80% of this budget triggers compaction.
    /// Nil = compaction off (default). Independent of `maxSystemChars`.
    public var maxContextTokens: Int?
    /// Most-recent turns kept verbatim when compacting (spec 2.5.0). Default 6.
    public var compactionKeepTurns: Int?
    /// Hard cap on how many recent session turns are replayed (spec 2.6.0).
    /// 0 replays none (summary only); nil replays all (default).
    public var sessionContextTurns: Int?
    /// Provider-specific options merged directly into the request payload.
    /// Examples: `["think": false]` for Ollama/Qwen3, `["temperature": 0.7]`.
    public var providerOptions: [String: JSONValue]

    public init(
        provider: String,
        model: String,
        timeoutSeconds: Double = 60.0,
        maxOutputTokens: Int? = nil,
        costLimit: Double? = nil,
        maxSystemChars: Int? = nil,
        maxContextTokens: Int? = nil,
        compactionKeepTurns: Int? = nil,
        sessionContextTurns: Int? = nil,
        providerOptions: [String: JSONValue] = [:]
    ) {
        self.provider = provider
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.maxOutputTokens = maxOutputTokens
        self.costLimit = costLimit
        self.maxSystemChars = maxSystemChars
        self.maxContextTokens = maxContextTokens
        self.compactionKeepTurns = compactionKeepTurns
        self.sessionContextTurns = sessionContextTurns
        self.providerOptions = providerOptions
    }
}
