import Foundation

/// Protocol for session persistence backends.
public protocol SessionStore: Sendable {
    /// Create a new session.
    /// - Parameters:
    ///   - profileName: Profile name for this session.
    ///   - sessionId: Explicit ID to use. If nil, a random UUID is generated.
    ///   - metadata: Optional initial metadata.
    func create(profileName: String, sessionId: String?, metadata: [String: JSONValue]?) async throws -> Session

    /// Retrieve a session by ID. Returns nil if not found.
    func get(_ sessionId: String) async throws -> Session?

    /// Persist a session (turns + metadata + updatedAt).
    func save(_ session: Session) async throws
}
