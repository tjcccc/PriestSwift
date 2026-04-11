/// All priest error codes. Raw values match the spec-defined strings.
public enum PriestErrorCode: String, Sendable {
    case profileNotFound      = "PROFILE_NOT_FOUND"
    case profileInvalid       = "PROFILE_INVALID"
    case sessionNotFound      = "SESSION_NOT_FOUND"
    case sessionStoreError    = "SESSION_STORE_ERROR"
    case providerNotRegistered = "PROVIDER_NOT_REGISTERED"
    case providerTimeout      = "PROVIDER_TIMEOUT"
    case providerError        = "PROVIDER_ERROR"
    case providerRateLimited  = "PROVIDER_RATE_LIMITED"
    case requestInvalid       = "REQUEST_INVALID"
    case internalError        = "INTERNAL_ERROR"
}

/// Base error type for all priest errors.
///
/// Two errors are always thrown as exceptions and never placed into PriestResponse.error:
/// - `.providerNotRegistered` — no adapter means no response can be constructed.
/// - `.sessionNotFound` — the caller explicitly opted out of session creation.
///
/// All other provider errors are caught and placed into PriestResponse.error.
public struct PriestError: Error, Sendable {
    public let code: PriestErrorCode
    public let message: String
    /// Structured details. All values are strings (non-string values are stringified at creation).
    public let details: [String: String]

    public init(code: PriestErrorCode, message: String, details: [String: String] = [:]) {
        self.code = code
        self.message = message
        self.details = details
    }
}

extension PriestError: CustomStringConvertible {
    public var description: String {
        "PriestError(\(code.rawValue): \(message))"
    }
}

// MARK: - Convenience constructors

extension PriestError {
    static func profileNotFound(_ name: String) -> PriestError {
        PriestError(code: .profileNotFound, message: "Profile '\(name)' not found", details: ["profile": name])
    }

    static func sessionNotFound(_ sessionId: String) -> PriestError {
        PriestError(code: .sessionNotFound, message: "Session '\(sessionId)' not found", details: ["session_id": sessionId])
    }

    static func providerNotRegistered(_ provider: String) -> PriestError {
        PriestError(code: .providerNotRegistered, message: "Provider '\(provider)' is not registered", details: ["provider": provider])
    }

    static func providerTimeout(_ provider: String, timeout: Double) -> PriestError {
        PriestError(code: .providerTimeout, message: "Provider '\(provider)' timed out after \(timeout)s", details: ["provider": provider, "timeout": String(timeout)])
    }

    static func providerError(_ provider: String, message: String) -> PriestError {
        PriestError(code: .providerError, message: "Provider '\(provider)' error: \(message)", details: ["provider": provider])
    }

    static func providerRateLimited(_ provider: String, retryAfter: Double? = nil) -> PriestError {
        var msg = "Provider '\(provider)' rate limited"
        var details: [String: String] = ["provider": provider]
        if let r = retryAfter {
            msg += " — retry after \(r)s"
            details["retry_after"] = String(r)
        }
        return PriestError(code: .providerRateLimited, message: msg, details: details)
    }
}
