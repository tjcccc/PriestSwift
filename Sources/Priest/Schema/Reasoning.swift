/// Provider-neutral reasoning effort. Support is provider- and model-specific.
public enum ReasoningEffort: String, Sendable, Codable, Equatable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
}

/// Requested behavior for provider-supplied displayable summaries.
public enum ReasoningSummaryMode: String, Sendable, Codable, Equatable {
    case none
    case auto
}

/// Optional provider-neutral reasoning request.
public struct ReasoningConfig: Sendable, Codable, Equatable {
    public var enabled: Bool?
    public var effort: ReasoningEffort?
    public var summary: ReasoningSummaryMode?

    public init(
        enabled: Bool? = nil,
        effort: ReasoningEffort? = nil,
        summary: ReasoningSummaryMode? = nil
    ) {
        self.enabled = enabled
        self.effort = effort
        self.summary = summary
    }
}

/// Provider-owned continuation state, replayed only to a recognizing adapter.
public struct OpaqueReasoningState: Sendable, Codable, Equatable {
    public let format: String
    public let value: JSONValue

    public init(format: String, value: JSONValue) {
        self.format = format
        self.value = value
    }
}

/// Safe provider-supplied reasoning information.
public struct ReasoningInfo: Sendable, Codable, Equatable {
    public let summary: String?
    public let continuation: [OpaqueReasoningState]?

    public init(summary: String? = nil, continuation: [OpaqueReasoningState]? = nil) {
        self.summary = summary
        self.continuation = continuation
    }
}
