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
    /// Provider-specific options merged directly into the request payload.
    /// Examples: `["think": false]` for Ollama/Qwen3, `["temperature": 0.7]`.
    public var providerOptions: [String: JSONValue]

    public init(
        provider: String,
        model: String,
        timeoutSeconds: Double = 60.0,
        maxOutputTokens: Int? = nil,
        costLimit: Double? = nil,
        providerOptions: [String: JSONValue] = [:]
    ) {
        self.provider = provider
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.maxOutputTokens = maxOutputTokens
        self.costLimit = costLimit
        self.providerOptions = providerOptions
    }
}
