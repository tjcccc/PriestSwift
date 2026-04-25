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
    /// JSON Schema for structured output.
    /// OpenAI-compat: maps to response_format={type:"json_schema",...}.
    /// Ollama (v0.5+): maps to format:<schema_dict>.
    /// Anthropic: schema description injected into system message (no native support).
    /// When set, takes precedence over providerFormat for the schema-capable path.
    public var jsonSchema: [String: JSONValue]?
    /// Schema name passed to OpenAI's json_schema.name field. Defaults to "response".
    public var jsonSchemaName: String
    /// Maps to OpenAI's json_schema.strict. Requires every property in required and
    /// additionalProperties:false. Most schemas won't satisfy this. Defaults to false.
    public var jsonSchemaStrict: Bool

    public static let none = OutputSpec()

    public init(
        providerFormat: ProviderFormat? = nil,
        promptFormat: PromptFormat? = nil,
        jsonSchema: [String: JSONValue]? = nil,
        jsonSchemaName: String = "response",
        jsonSchemaStrict: Bool = false
    ) {
        self.providerFormat = providerFormat
        self.promptFormat = promptFormat
        self.jsonSchema = jsonSchema
        self.jsonSchemaName = jsonSchemaName
        self.jsonSchemaStrict = jsonSchemaStrict
    }
}
