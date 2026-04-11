import Foundation

/// In-memory session store for testing and ephemeral sessions.
/// Uses an actor for safe concurrent access.
public actor InMemorySessionStore: SessionStore {
    private var sessions: [String: Session] = [:]

    public init() {}

    public func create(profileName: String, sessionId: String? = nil, metadata: [String: JSONValue]? = nil) async throws -> Session {
        let id = sessionId ?? UUID().uuidString
        let session = Session(id: id, profileName: profileName, metadata: metadata ?? [:])
        sessions[id] = session
        return session
    }

    public func get(_ sessionId: String) async throws -> Session? {
        sessions[sessionId]
    }

    public func save(_ session: Session) async throws {
        sessions[session.id] = session
    }
}
