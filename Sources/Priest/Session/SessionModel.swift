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

    // MARK: - Conversation compaction (spec 2.5.0)

    /// Reserved metadata key holding the conversation-compaction state. The
    /// stored object uses EXACT camelCase field names — a cross-SDK contract;
    /// see spec/behavior/session-lifecycle.md.
    public static let compactionMetadataKey = "__compaction"

    /// Read compaction state from metadata. Empty state when unset.
    public func getCompaction() -> CompactionState {
        guard case let .object(obj)? = metadata[Self.compactionMetadataKey] else {
            return CompactionState()
        }
        var state = CompactionState()
        if case let .string(v)? = obj["summary"] { state.summary = v }
        if case let .int(v)? = obj["summarizedThrough"] { state.summarizedThrough = v }
        if case let .int(v)? = obj["lastInputTokens"] { state.lastInputTokens = v }
        if case let .string(v)? = obj["updatedAt"] { state.updatedAt = v }
        return state
    }

    /// Serialize compaction state into metadata using the camelCase wire keys.
    private func setCompaction(_ state: CompactionState) {
        var obj: [String: JSONValue] = ["summarizedThrough": .int(state.summarizedThrough)]
        if let summary = state.summary { obj["summary"] = .string(summary) }
        if let last = state.lastInputTokens { obj["lastInputTokens"] = .int(last) }
        if let updated = state.updatedAt { obj["updatedAt"] = .string(updated) }
        metadata[Self.compactionMetadataKey] = .object(obj)
        updatedAt = Date()
    }

    /// Record the most recent turn's input size (the compaction trigger signal).
    public func recordInputTokens(_ tokens: Int?) {
        guard let tokens else { return }
        var state = getCompaction()
        state.lastInputTokens = tokens
        setCompaction(state)
    }

    /// Fold turns[0 ..< summarizedThrough) into `summary`; raw turns stay intact.
    public func applyCompaction(summary: String, summarizedThrough: Int) {
        var state = getCompaction()
        state.summary = summary
        state.summarizedThrough = summarizedThrough
        state.updatedAt = Self.compactionTimestampFormatter.string(from: Date())
        setCompaction(state)
    }

    /// Canonical priest timestamp format (`yyyy-MM-ddTHH:mm:ss.ffffff+00:00`),
    /// matching session-lifecycle.md so `__compaction.updatedAt` is consistent
    /// with the other SDKs.
    private static let compactionTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
        return f
    }()
}

/// Decoded view of `session.metadata["__compaction"]` (spec 2.5.0).
public struct CompactionState: Sendable {
    /// Running synopsis covering turns[0 ..< summarizedThrough).
    public var summary: String?
    /// Number of leading turns folded into `summary` (index into turns).
    public var summarizedThrough: Int
    /// Provider-reported input tokens of the most recent measured (chat) turn — the trigger signal.
    public var lastInputTokens: Int?
    /// ISO-8601 timestamp of the last compaction-state update.
    public var updatedAt: String?

    public init(summary: String? = nil, summarizedThrough: Int = 0, lastInputTokens: Int? = nil, updatedAt: String? = nil) {
        self.summary = summary
        self.summarizedThrough = summarizedThrough
        self.lastInputTokens = lastInputTokens
        self.updatedAt = updatedAt
    }
}
