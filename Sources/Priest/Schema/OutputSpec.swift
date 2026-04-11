/// Provider-native output format hint.
/// Currently only `.json` has broad provider-native support.
public enum ProviderFormat: String, Sendable {
    case json
}

/// Natural-language format instruction injected into the system prompt.
/// See `behavior/context-assembly.md` for the exact instruction strings.
public enum PromptFormat: String, Sendable {
    case json
    case xml
    case code
}

/// Output format hints for a priest request.
///
/// Both fields are optional and independent — either, both, or neither may be set.
/// The engine never parses response text; `PriestResponse.text` is always the raw string.
public struct OutputSpec: Sendable {
    /// Activates provider-native structured output (e.g. Ollama `format` field,
    /// OpenAI `response_format`). Nil means no provider-native hint.
    public var providerFormat: ProviderFormat?
    /// Injects a natural-language format instruction into the system prompt.
    /// Works with any provider regardless of native support. Nil means no injection.
    public var promptFormat: PromptFormat?

    public static let none = OutputSpec()

    public init(providerFormat: ProviderFormat? = nil, promptFormat: PromptFormat? = nil) {
        self.providerFormat = providerFormat
        self.promptFormat = promptFormat
    }
}
