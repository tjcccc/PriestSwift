import Foundation

/// Orchestrates a single AI run.
///
/// The engine is stateless per-run — it holds no mutable state between calls.
/// Profile caching, if needed, should be implemented in the host app's
/// ProfileLoader wrapper.
///
/// Spec version this implementation targets: 1.0.0
public final class PriestEngine: Sendable {

    /// Spec version this implementation targets. A test should assert this matches
    /// the known spec version to catch sync drift between the spec and this SDK.
    public static let specVersion = "2.2.0"

    private let profileLoader: any ProfileLoader
    private let sessionStore: (any SessionStore)?
    private let adapters: [String: any ProviderAdapter]

    public init(
        profileLoader: any ProfileLoader,
        sessionStore: (any SessionStore)? = nil,
        adapters: [String: any ProviderAdapter] = [:]
    ) {
        self.profileLoader = profileLoader
        self.sessionStore = sessionStore
        self.adapters = adapters
    }

    // MARK: - run

    /// Execute a single request and return a structured response.
    ///
    /// - Throws: `PriestError` with code `.providerNotRegistered` if no adapter
    ///   is registered for `request.config.provider`.
    /// - Throws: `PriestError` with code `.sessionNotFound` if the session
    ///   cannot be found and `createIfMissing` is false.
    /// - Returns: `PriestResponse` — `ok` is false and `error` is set on provider failure.
    public func run(_ request: PriestRequest) async throws -> PriestResponse {
        let startMs = Int(Date().timeIntervalSince1970 * 1000)

        // Resolve adapter — throws if not registered
        guard let adapter = adapters[request.config.provider] else {
            throw PriestError.providerNotRegistered(request.config.provider)
        }

        // Load profile
        let profile = try profileLoader.load(request.profile)

        // Session handling
        let (session, isNewSession) = try await resolveSession(request: request)

        // Build messages
        let messages = buildMessages(
            profile: profile,
            session: session,
            prompt: request.prompt,
            context: request.context,
            memory: request.memory,
            userContext: request.userContext,
            outputSpec: request.output,
            maxSystemChars: request.config.maxSystemChars
        )

        // Call provider
        var text: String? = nil
        var finishReason: String? = nil
        var inputTokens: Int? = nil
        var outputTokens: Int? = nil
        var errorModel: PriestErrorModel? = nil

        do {
            let result = try await adapter.complete(messages: messages, config: request.config, outputSpec: request.output)
            text = result.text
            finishReason = result.finishReason
            inputTokens = result.inputTokens
            outputTokens = result.outputTokens
        } catch let e as PriestError {
            finishReason = "error"
            errorModel = PriestErrorModel(code: e.code.rawValue, message: e.message, details: e.details)
        } catch {
            finishReason = "error"
            errorModel = PriestErrorModel(code: PriestErrorCode.internalError.rawValue, message: error.localizedDescription, details: [:])
        }

        // Save session on success
        var sessionInfo: SessionInfo? = nil
        if let session = session, let store = sessionStore, errorModel == nil {
            session.appendTurn(role: .user, content: request.prompt)
            if let t = text { session.appendTurn(role: .assistant, content: t) }
            try await store.save(session)
            sessionInfo = SessionInfo(id: session.id, isNew: isNewSession, turnCount: session.turns.count)
        }

        let latencyMs = Int(Date().timeIntervalSince1970 * 1000) - startMs

        var usage: UsageInfo? = nil
        if inputTokens != nil || outputTokens != nil {
            let total = (inputTokens ?? 0) + (outputTokens ?? 0)
            usage = UsageInfo(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                totalTokens: total > 0 ? total : nil,
                estimatedCostUSD: nil
            )
        }

        return PriestResponse(
            text: text,
            execution: ExecutionInfo(
                provider: request.config.provider,
                model: request.config.model,
                latencyMs: latencyMs,
                profile: request.profile,
                finishedReason: finishReason.flatMap { FinishedReason(rawValue: $0) }
            ),
            usage: usage,
            session: sessionInfo,
            error: errorModel,
            metadata: request.metadata
        )
    }

    // MARK: - stream

    /// Yield text chunks as they arrive from the provider.
    ///
    /// Session is saved automatically after the stream completes.
    /// Throws `PriestError` on provider failure.
    ///
    /// Note: unlike run(), stream() yields only raw text chunks — there is no
    /// final PriestResponse. Usage stats, latency, and session info are not
    /// returned. If you need structured metadata, use run() instead.
    public func stream(_ request: PriestRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let adapter = self.adapters[request.config.provider] else {
                        throw PriestError.providerNotRegistered(request.config.provider)
                    }
                    let profile = try self.profileLoader.load(request.profile)
                    let (session, _) = try await self.resolveSession(request: request)
                    let messages = buildMessages(
                        profile: profile,
                        session: session,
                        prompt: request.prompt,
                        context: request.context,
                        memory: request.memory,
                        userContext: request.userContext,
                        outputSpec: request.output,
                        maxSystemChars: request.config.maxSystemChars
                    )

                    var parts: [String] = []
                    for try await chunk in adapter.stream(messages: messages, config: request.config, outputSpec: request.output) {
                        parts.append(chunk)
                        continuation.yield(chunk)
                    }

                    // Save session after stream completes
                    if let session = session, let store = self.sessionStore, !parts.isEmpty {
                        let fullText = parts.joined()
                        session.appendTurn(role: .user, content: request.prompt)
                        session.appendTurn(role: .assistant, content: fullText)
                        try await store.save(session)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Session resolution

    private func resolveSession(request: PriestRequest) async throws -> (Session?, Bool) {
        guard let sessionRef = request.session, let store = sessionStore else {
            return (nil, false)
        }

        if sessionRef.continueExisting {
            if let existing = try await store.get(sessionRef.id) {
                return (existing, false)
            }
            if sessionRef.createIfMissing {
                let session = try await store.create(profileName: request.profile, sessionId: sessionRef.id, metadata: nil)
                return (session, true)
            }
            throw PriestError.sessionNotFound(sessionRef.id)
        } else {
            let session = try await store.create(profileName: request.profile, sessionId: nil, metadata: nil)
            return (session, true)
        }
    }
}
