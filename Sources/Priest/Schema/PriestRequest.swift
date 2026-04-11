/// A single engine run request.
public struct PriestRequest: Sendable {
    /// Provider and model configuration.
    public var config: PriestConfig
    /// Profile name to load. Defaults to "default".
    public var profile: String
    /// The user's prompt. Becomes the content of the final user message.
    public var prompt: String
    /// Session reference. If nil, no session is created or continued.
    public var session: SessionRef?
    /// App-layer strings injected at the top of the system prompt.
    /// Use for runtime policy: current date, environment name, guardrails, etc.
    public var systemContext: [String]
    /// Additional strings appended to the user turn after the prompt.
    public var extraContext: [String]
    /// Output format hints.
    public var output: OutputSpec
    /// Arbitrary caller metadata. Echoed unchanged into PriestResponse.metadata.
    public var metadata: [String: JSONValue]

    public init(
        config: PriestConfig,
        prompt: String,
        profile: String = "default",
        session: SessionRef? = nil,
        systemContext: [String] = [],
        extraContext: [String] = [],
        output: OutputSpec = .none,
        metadata: [String: JSONValue] = [:]
    ) {
        self.config = config
        self.prompt = prompt
        self.profile = profile
        self.session = session
        self.systemContext = systemContext
        self.extraContext = extraContext
        self.output = output
        self.metadata = metadata
    }
}
