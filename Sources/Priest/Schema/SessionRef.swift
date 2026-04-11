/// Reference to a session to create or continue.
public struct SessionRef: Sendable {
    /// Session identifier. When `createIfMissing` is true, this exact ID is used —
    /// session creation is idempotent on the same ID.
    public var id: String
    /// If true, look up the session by ID before creating.
    /// If false, always create a new session (ID is ignored for lookup).
    public var continueExisting: Bool
    /// Only relevant when `continueExisting` is true.
    /// If the session does not exist: true creates it with the provided ID;
    /// false throws `.sessionNotFound`.
    public var createIfMissing: Bool

    public init(id: String, continueExisting: Bool = true, createIfMissing: Bool = true) {
        self.id = id
        self.continueExisting = continueExisting
        self.createIfMissing = createIfMissing
    }
}
