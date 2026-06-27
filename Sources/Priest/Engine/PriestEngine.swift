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
    public static let specVersion = "2.6.1"

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

        // Compaction (spec 2.5.0): fold older turns before building messages.
        if let session = session { try await maybeCompact(session, config: request.config) }

        // Build messages
        let messages = buildMessages(
            profile: profile,
            session: session,
            prompt: request.prompt,
            context: request.context,
            memory: request.memory,
            userContext: request.userContext,
            outputSpec: request.output,
            maxSystemChars: request.config.maxSystemChars,
            toolExchange: request.toolExchange,
            sessionContextTurns: request.config.sessionContextTurns
        )

        // Call provider
        var text: String? = nil
        var toolCalls: [ToolCall]? = nil
        var finishReason: String? = nil
        var inputTokens: Int? = nil
        var outputTokens: Int? = nil
        var cachedInputTokens: Int? = nil
        var errorModel: PriestErrorModel? = nil

        do {
            let result = try await adapter.complete(
                messages: messages,
                config: request.config,
                outputSpec: request.output,
                options: Self.callOptions(for: request)
            )
            text = result.text
            toolCalls = (result.toolCalls?.isEmpty == false) ? result.toolCalls : nil
            finishReason = result.finishReason
            inputTokens = result.inputTokens
            outputTokens = result.outputTokens
            cachedInputTokens = result.cachedInputTokens
            if toolCalls != nil { finishReason = "tool_calls" }
        } catch let e as PriestError {
            finishReason = "error"
            errorModel = PriestErrorModel(code: e.code.rawValue, message: e.message, details: e.details)
        } catch {
            finishReason = "error"
            errorModel = PriestErrorModel(code: PriestErrorCode.internalError.rawValue, message: error.localizedDescription, details: [:])
        }

        // Save session on success. Tool-call iterations are turn-local: persist
        // only when the model produced a final answer (spec behavior/tool-calling.md).
        var sessionInfo: SessionInfo? = nil
        if let session = session, let store = sessionStore, errorModel == nil {
            if toolCalls == nil {
                session.appendTurn(role: .user, content: request.prompt)
                if let t = text { session.appendTurn(role: .assistant, content: t) }
                Self.recordChatUsage(session, request: request, inputTokens: inputTokens)
                try await store.save(session)
            }
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
                cachedInputTokens: cachedInputTokens,
                estimatedCostUSD: nil
            )
        }

        return PriestResponse(
            text: text,
            toolCalls: toolCalls,
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
                    if let session = session { try await self.maybeCompact(session, config: request.config) }
                    let messages = buildMessages(
                        profile: profile,
                        session: session,
                        prompt: request.prompt,
                        context: request.context,
                        memory: request.memory,
                        userContext: request.userContext,
                        outputSpec: request.output,
                        maxSystemChars: request.config.maxSystemChars,
                        toolExchange: request.toolExchange,
                        sessionContextTurns: request.config.sessionContextTurns
                    )

                    var parts: [String] = []
                    for try await chunk in adapter.stream(
                        messages: messages,
                        config: request.config,
                        outputSpec: request.output,
                        options: Self.callOptions(for: request)
                    ) {
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

    // MARK: - Structured streaming (spec 2.4.0)

    /// Yield structured streaming events: text deltas, tool-call progress,
    /// usage, and a terminal "done" event carrying the full PriestResponse.
    /// Provider errors surface in done.response?.error rather than being
    /// thrown, matching run() semantics.
    public func streamEvents(_ request: PriestRequest) -> AsyncThrowingStream<PriestStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let startMs = Int(Date().timeIntervalSince1970 * 1000)
                    guard let adapter = self.adapters[request.config.provider] else {
                        throw PriestError.providerNotRegistered(request.config.provider)
                    }
                    let profile = try self.profileLoader.load(request.profile)
                    let (session, isNewSession) = try await self.resolveSession(request: request)
                    if let session = session { try await self.maybeCompact(session, config: request.config) }
                    let messages = buildMessages(
                        profile: profile,
                        session: session,
                        prompt: request.prompt,
                        context: request.context,
                        memory: request.memory,
                        userContext: request.userContext,
                        outputSpec: request.output,
                        maxSystemChars: request.config.maxSystemChars,
                        toolExchange: request.toolExchange,
                        sessionContextTurns: request.config.sessionContextTurns
                    )

                    var textParts: [String] = []
                    var toolCalls: [ToolCall] = []
                    var finishReason: String? = nil
                    var inputTokens: Int? = nil
                    var outputTokens: Int? = nil
                    var cachedInputTokens: Int? = nil
                    var errorModel: PriestErrorModel? = nil

                    do {
                        for try await event in adapter.streamEvents(
                            messages: messages,
                            config: request.config,
                            outputSpec: request.output,
                            options: Self.callOptions(for: request)
                        ) {
                            switch event.type {
                            case "text_delta":
                                if let text = event.text, !text.isEmpty {
                                    textParts.append(text)
                                    var out = PriestStreamEvent(type: "text_delta")
                                    out.text = text
                                    continuation.yield(out)
                                }
                            case "tool_call_start", "tool_call_delta":
                                var out = PriestStreamEvent(type: event.type)
                                out.index = event.index
                                out.id = event.id
                                out.name = event.name
                                out.argumentsDelta = event.argumentsDelta
                                continuation.yield(out)
                            case "tool_call_end":
                                if let call = event.toolCall {
                                    toolCalls.append(call)
                                    var out = PriestStreamEvent(type: "tool_call_end")
                                    out.index = event.index
                                    out.toolCall = call
                                    continuation.yield(out)
                                }
                            case "usage":
                                inputTokens = event.inputTokens ?? inputTokens
                                outputTokens = event.outputTokens ?? outputTokens
                                cachedInputTokens = event.cachedInputTokens ?? cachedInputTokens
                                var out = PriestStreamEvent(type: "usage")
                                out.inputTokens = inputTokens
                                out.outputTokens = outputTokens
                                out.cachedInputTokens = cachedInputTokens
                                continuation.yield(out)
                            case "finish":
                                finishReason = event.finishReason ?? finishReason
                            default:
                                break
                            }
                        }
                    } catch let e as PriestError {
                        finishReason = "error"
                        errorModel = PriestErrorModel(code: e.code.rawValue, message: e.message, details: e.details)
                    } catch {
                        finishReason = "error"
                        errorModel = PriestErrorModel(code: PriestErrorCode.internalError.rawValue, message: error.localizedDescription, details: [:])
                    }

                    let text = textParts.isEmpty ? nil : textParts.joined()
                    if !toolCalls.isEmpty && finishReason != "error" { finishReason = "tool_calls" }

                    var sessionInfo: SessionInfo? = nil
                    if let session = session, let store = self.sessionStore, errorModel == nil {
                        if toolCalls.isEmpty, let fullText = text {
                            session.appendTurn(role: .user, content: request.prompt)
                            session.appendTurn(role: .assistant, content: fullText)
                            Self.recordChatUsage(session, request: request, inputTokens: inputTokens)
                            try await store.save(session)
                        }
                        sessionInfo = SessionInfo(id: session.id, isNew: isNewSession, turnCount: session.turns.count)
                    }

                    var usage: UsageInfo? = nil
                    if inputTokens != nil || outputTokens != nil {
                        let total = (inputTokens ?? 0) + (outputTokens ?? 0)
                        usage = UsageInfo(
                            inputTokens: inputTokens,
                            outputTokens: outputTokens,
                            totalTokens: total > 0 ? total : nil,
                            cachedInputTokens: cachedInputTokens,
                            estimatedCostUSD: nil
                        )
                    }

                    let response = PriestResponse(
                        text: text,
                        toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                        execution: ExecutionInfo(
                            provider: request.config.provider,
                            model: request.config.model,
                            latencyMs: Int(Date().timeIntervalSince1970 * 1000) - startMs,
                            profile: request.profile,
                            finishedReason: finishReason.flatMap { FinishedReason(rawValue: $0) }
                        ),
                        usage: usage,
                        session: sessionInfo,
                        error: errorModel,
                        metadata: request.metadata
                    )
                    var done = PriestStreamEvent(type: "done")
                    done.response = response
                    continuation.yield(done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private static func callOptions(for request: PriestRequest) -> AdapterCallOptions? {
        request.tools.isEmpty ? nil : AdapterCallOptions(tools: request.tools, toolChoice: request.toolChoice)
    }

    // MARK: - Conversation compaction (spec 2.5.0)

    /// Compact a session on demand: fold older turns into the running summary,
    /// keeping the most recent `compactionKeepTurns`. Returns whether anything was
    /// folded and the new coverage point. Throws `.sessionNotFound` for unknown ids.
    public func compactSession(_ sessionId: String, config: PriestConfig) async throws -> (compacted: Bool, summarizedThrough: Int) {
        guard let store = sessionStore else { return (false, 0) }
        guard let session = try await store.get(sessionId) else {
            throw PriestError.sessionNotFound(sessionId)
        }
        let compacted = try await compact(session, config: config)
        return (compacted, session.getCompaction().summarizedThrough)
    }

    /// Record a turn's input size as the compaction trigger signal. Skipped when
    /// the turn replays a tool exchange (its input is inflated by tool context).
    private static func recordChatUsage(_ session: Session, request: PriestRequest, inputTokens: Int?) {
        if !request.toolExchange.isEmpty { return }
        session.recordInputTokens(inputTokens)
    }

    /// Compact before a turn when the previous turn's input usage crossed the budget.
    private func maybeCompact(_ session: Session, config: PriestConfig) async throws {
        guard sessionStore != nil else { return }
        guard shouldCompact(lastInputTokens: session.getCompaction().lastInputTokens, maxContextTokens: config.maxContextTokens) else { return }
        _ = try await compact(session, config: config)
    }

    /// Fold turns into the summary via a provider summarization call; persists the result.
    @discardableResult
    private func compact(_ session: Session, config: PriestConfig) async throws -> Bool {
        guard let store = sessionStore else { return false }
        let keepTurns = config.compactionKeepTurns ?? defaultCompactionKeepTurns
        let existing = session.getCompaction()
        guard let plan = planCompaction(turns: session.turns, alreadySummarizedThrough: existing.summarizedThrough, keepTurns: keepTurns) else {
            return false
        }
        guard let adapter = adapters[config.provider] else {
            throw PriestError.providerNotRegistered(config.provider)
        }
        let messages = buildSummaryMessages(existingSummary: existing.summary, toSummarize: plan.toSummarize)
        var summaryConfig = config
        if summaryConfig.maxOutputTokens == nil { summaryConfig.maxOutputTokens = summaryMaxOutputTokens }
        let result = try await adapter.complete(messages: messages, config: summaryConfig, outputSpec: OutputSpec(), options: nil)
        let summary = (result.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.isEmpty { return false }
        session.applyCompaction(summary: summary, summarizedThrough: plan.summarizedThrough)
        try await store.save(session)
        return true
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
