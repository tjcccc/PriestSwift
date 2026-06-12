/// Generic caller-executes tool loop (spec 2.4.0, behavior/tool-calling.md).

public struct ToolExecutionResult: Sendable {
    public let content: String
    public let isError: Bool

    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

public struct ApprovalDecision: Sendable {
    public let approved: Bool
    public let reason: String?

    public init(approved: Bool, reason: String? = nil) {
        self.approved = approved
        self.reason = reason
    }
}

/// Result of a runWithTools loop.
public struct ToolLoopResult: Sendable {
    /// The final response — the first one without tool calls, or the last
    /// iteration's response when the cap was hit or an error occurred.
    public let response: PriestResponse
    /// Full tool exchange trace accumulated across iterations.
    public let exchange: [ToolExchangeTurn]
    /// True when the loop stopped because the iteration cap was reached.
    public let iterationLimitReached: Bool
}

/// Run the request, execute tool calls through the caller-supplied executor,
/// replay results via toolExchange, and repeat until the model answers
/// without tool calls or the iteration cap is hit. The library never chooses
/// or sandboxes tools — policy belongs to the caller via the executor and the
/// onToolCall approval hook (defaults to approving everything).
public func runWithTools(
    engine: PriestEngine,
    request: PriestRequest,
    executor: @Sendable (ToolCall) async -> ToolExecutionResult,
    onToolCall: (@Sendable (ToolCall) async -> ApprovalDecision)? = nil,
    maxIterations: Int = 10
) async throws -> ToolLoopResult {
    let maxIterations = max(1, maxIterations)
    var exchange = request.toolExchange

    var response: PriestResponse? = nil
    for _ in 0..<maxIterations {
        var iterationRequest = request
        iterationRequest.toolExchange = exchange
        let current = try await engine.run(iterationRequest)

        guard current.ok, let calls = current.toolCalls, !calls.isEmpty else {
            return ToolLoopResult(response: current, exchange: exchange, iterationLimitReached: false)
        }

        exchange.append(.assistant(text: current.text, toolCalls: calls))
        for call in calls {
            let decision = await onToolCall?(call) ?? ApprovalDecision(approved: true)
            if !decision.approved {
                let reason = decision.reason.map { ": \($0)" } ?? "."
                exchange.append(.toolResult(
                    toolCallId: call.id,
                    name: call.name,
                    content: "Tool call denied by the caller\(reason)",
                    isError: true
                ))
                continue
            }
            let result = await executor(call)
            exchange.append(.toolResult(
                toolCallId: call.id,
                name: call.name,
                content: result.content,
                isError: result.isError
            ))
        }
        response = current
    }

    // maxIterations is clamped to >= 1, so response is always set here.
    return ToolLoopResult(response: response!, exchange: exchange, iterationLimitReached: true)
}
