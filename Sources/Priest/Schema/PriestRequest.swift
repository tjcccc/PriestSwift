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
    /// Raw, passed through untouched. Use for runtime policy: current date, environment name, guardrails.
    public var context: [String]
    /// Dynamic memory entries. Deduped against profile memories and each other. Subject to tail-trim.
    public var memory: [String]
    /// Strings appended to the user turn after the prompt, joined with \n\n.
    public var userContext: [String]
    /// Output format hints.
    public var output: OutputSpec
    /// Arbitrary caller metadata. Echoed unchanged into PriestResponse.metadata.
    public var metadata: [String: JSONValue]

    public init(
        config: PriestConfig,
        prompt: String,
        profile: String = "default",
        session: SessionRef? = nil,
        context: [String] = [],
        memory: [String] = [],
        userContext: [String] = [],
        output: OutputSpec = .none,
        metadata: [String: JSONValue] = [:]
    ) {
        self.config = config
        self.prompt = prompt
        self.profile = profile
        self.session = session
        self.context = context
        self.memory = memory
        self.userContext = userContext
        self.output = output
        self.metadata = metadata
    }
}
