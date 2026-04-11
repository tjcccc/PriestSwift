/// Normalized finish reason returned by the engine.
public enum FinishedReason: String, Sendable {
    case stop
    case length
    case error
    case unknown
}

/// Execution metadata for a completed run.
public struct ExecutionInfo: Sendable {
    public let provider: String
    public let model: String
    /// Wall-clock time from start to return, in milliseconds.
    public let latencyMs: Int?
    public let profile: String
    public let finishedReason: FinishedReason?
}

/// Token usage reported by the provider.
public struct UsageInfo: Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    /// inputTokens + outputTokens. Nil if both are nil.
    public let totalTokens: Int?
    public let estimatedCostUSD: Double?
}

/// Session state after a run.
public struct SessionInfo: Sendable {
    public let id: String
    /// True if this run created the session.
    public let isNew: Bool
    /// Total number of turns in the session after this run.
    public let turnCount: Int
}

/// Structured error placed into PriestResponse when a provider call fails.
/// Distinct from the thrown PriestError exception (which is for PROVIDER_NOT_REGISTERED
/// and SESSION_NOT_FOUND — errors where no response can be constructed).
public struct PriestErrorModel: Sendable {
    public let code: String
    public let message: String
    /// Detail values are always strings.
    public let details: [String: String]
}

/// Result of a single engine run.
public struct PriestResponse: Sendable {
    /// Raw text returned by the provider. Always the unmodified string.
    /// Nil on error or when the provider returned no content.
    public let text: String?
    public let execution: ExecutionInfo
    /// Token usage. Nil if the provider did not report usage data.
    public let usage: UsageInfo?
    /// Session state after this run. Nil if no session was used.
    public let session: SessionInfo?
    /// Error details if the run failed. Nil on success.
    public let error: PriestErrorModel?
    /// Caller metadata echoed from PriestRequest.metadata unchanged.
    public let metadata: [String: JSONValue]

    /// True when error is nil.
    public var ok: Bool { error == nil }
}
