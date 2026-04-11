import Foundation

/// A single conversation turn.
public struct Turn: Sendable {
    public enum Role: String, Sendable {
        case user
        case assistant
    }

    public let role: Role
    public let content: String
    public let timestamp: Date

    public init(role: Role, content: String, timestamp: Date = Date()) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

/// A conversation session containing an ordered list of turns.
///
/// `Session` is a class (reference type) because it is mutated in place via
/// `appendTurn()`, and the same instance is referenced between the pre-provider
/// call and the post-save phase in the engine.
public final class Session: @unchecked Sendable {
    public let id: String
    public let profileName: String
    public let createdAt: Date
    public private(set) var updatedAt: Date
    public private(set) var turns: [Turn]
    public var metadata: [String: JSONValue]

    public init(
        id: String,
        profileName: String,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        turns: [Turn] = [],
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.profileName = profileName
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.turns = turns
        self.metadata = metadata
    }

    public func appendTurn(role: Turn.Role, content: String) {
        turns.append(Turn(role: role, content: content))
        updatedAt = Date()
    }
}
