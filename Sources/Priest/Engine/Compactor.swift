import Foundation

/// Conversation compaction primitives (spec 2.5.0).
///
/// Long sessions replay their full turn history on every call, so input cost
/// grows linearly per turn and quadratically over a session. Compaction folds
/// the older turns into a running summary and replays only a recent tail. It is
/// non-destructive: raw turns stay in the store; only the replayed view shrinks.
/// The summary lives in session metadata (see `Session`).

/// Compact when the previous turn's input usage exceeds this fraction of the budget.
public let compactionTriggerRatio = 0.8
/// Most-recent turns kept verbatim; older turns fold into the summary.
public let defaultCompactionKeepTurns = 6
/// Output cap for the summary-generation call (keeps the summary itself bounded).
public let summaryMaxOutputTokens = 1024

/// A planned compaction round.
public struct CompactionPlan: Sendable {
    /// Turns to fold this round (after what's already summarized, before the tail).
    public let toSummarize: [Turn]
    /// Index into session.turns the new summary will cover up to.
    public let summarizedThrough: Int
}

/// Whether the previous turn's input size warrants compaction. Off when no budget is set.
public func shouldCompact(lastInputTokens: Int?, maxContextTokens: Int?) -> Bool {
    guard let budget = maxContextTokens, budget > 0 else { return false }
    guard let last = lastInputTokens else { return false }
    return Double(last) > Double(budget) * compactionTriggerRatio
}

/// Plan a compaction round: fold every turn after what's already summarized and
/// before the kept tail. Returns nil when there is nothing new to fold.
public func planCompaction(turns: [Turn], alreadySummarizedThrough: Int, keepTurns: Int) -> CompactionPlan? {
    let tailStart = max(0, turns.count - max(0, keepTurns))
    if tailStart <= alreadySummarizedThrough { return nil }
    return CompactionPlan(
        toSummarize: Array(turns[alreadySummarizedThrough..<tailStart]),
        summarizedThrough: tailStart
    )
}

private let summarySystem = [
    "You compress prior conversation into a compact running summary so the assistant can continue without the full transcript.",
    "Preserve the user's goals and constraints, decisions made, facts established within the conversation, and open or unresolved threads.",
    "Durable user facts are stored separately as memory — do not re-list them. Capture the conversation's trajectory and the context needed to continue it.",
    "Write a tight synopsis, not a turn-by-turn log. When an earlier summary is provided, merge the new turns into it and return a single updated summary with no preamble.",
].joined(separator: " ")

/// Build the messages for the summary-generation call (existing summary + new turns → one updated summary).
public func buildSummaryMessages(existingSummary: String?, toSummarize: [Turn]) -> [ChatMessage] {
    let transcript = toSummarize
        .map { "\($0.role.rawValue.uppercased()): \($0.content)" }
        .joined(separator: "\n\n")
    let user: String
    if let prior = existingSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !prior.isEmpty {
        user = "Existing summary so far:\n\n\(prior)\n\n---\n\nNew conversation turns to fold in:\n\n\(transcript)\n\n---\n\nReturn one updated summary."
    } else {
        user = "Conversation turns to summarize:\n\n\(transcript)\n\n---\n\nReturn the summary."
    }
    return [
        ChatMessage(role: "system", content: summarySystem),
        ChatMessage(role: "user", content: user),
    ]
}
