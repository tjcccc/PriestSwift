/// Loaded profile passed to the engine.
///
/// This is the in-memory form after filesystem loading.
/// See `behavior/profile-loading.md` for the filesystem layout.
public struct Profile: Sendable {
    /// Profile name, matching the directory name used to load it.
    public let name: String
    /// Content of PROFILE.md (identity and behavior text).
    public let identity: String
    /// Content of RULES.md. Empty string if absent.
    public let rules: String
    /// Content of CUSTOM.md. Empty string if absent.
    public let custom: String
    /// Contents of memory files from the memories/ subdirectory.
    /// Loaded in ascending lexicographic order by filename.
    public let memories: [String]
    /// Parsed content of profile.toml. Reserved for future use.
    public let meta: [String: JSONValue]

    public init(
        name: String,
        identity: String,
        rules: String = "",
        custom: String = "",
        memories: [String] = [],
        meta: [String: JSONValue] = [:]
    ) {
        self.name = name
        self.identity = identity
        self.rules = rules
        self.custom = custom
        self.memories = memories
        self.meta = meta
    }
}
