import Foundation

/// Assembles the ordered message list passed to a provider adapter.
///
/// This is a pure function that must reproduce the spec algorithm exactly.
/// See `behavior/context-assembly.md` for the full specification.

// MARK: - Spec constants (MUST NOT be modified without a spec version bump)

private let formatInstructions: [PromptFormat: String] = [
    .json: "Respond only with valid JSON. No prose, no markdown code fences.",
    .xml:  "Respond only with valid XML. No prose, no markdown code fences.",
    .code: "Respond only with code. No prose, no markdown code fences around it.",
]

private let memoriesHeader       = "## Loaded Memories\n\n"
private let dynamicMemoryHeader  = "## Memory\n\n"
private let summaryHeader         = "## Conversation so far (summary)\n\n"
private let sectionSeparator     = "\n\n"
private let memorySeparator      = "\n"

// MARK: - Assembly

func buildMessages(
    profile: Profile,
    session: Session?,
    prompt: String,
    context: [String],
    memory: [String],
    userContext: [String],
    outputSpec: OutputSpec,
    maxSystemChars: Int? = nil,
    toolExchange: [ToolExchangeTurn] = [],
    sessionContextTurns: Int? = nil
) -> [ChatMessage] {

    // Compaction summary (spec 2.5.0): stands in for the folded-away leading
    // turns, which are skipped in the history window below.
    let compaction = session?.getCompaction()
    let conversationSummary = compaction?.summary
    let summarizedThrough = compaction?.summarizedThrough ?? 0

    // Step 1 — normalize profile memories
    var profileMemories = profile.memories
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    // Step 2 — deduplicate dynamic memory
    var seen = Set(profileMemories)
    var dynamicMemory: [String] = []
    for entry in memory {
        let stripped = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { continue }
        guard seen.insert(stripped).inserted else { continue }
        dynamicMemory.append(stripped)
    }

    // Step 3 — trim to budget (only when maxSystemChars is set)
    if let budget = maxSystemChars {
        let fmtStr = outputSpec.promptFormat.flatMap { formatInstructions[$0] }
        while !dynamicMemory.isEmpty &&
              assembleSystemContent(context: context, profile: profile, profileMemories: profileMemories,
                                    dynamicMemory: dynamicMemory, formatInstruction: fmtStr, conversationSummary: conversationSummary).count > budget {
            dynamicMemory.removeLast()
        }
        while !profileMemories.isEmpty &&
              assembleSystemContent(context: context, profile: profile, profileMemories: profileMemories,
                                    dynamicMemory: dynamicMemory, formatInstruction: fmtStr, conversationSummary: conversationSummary).count > budget {
            profileMemories.removeLast()
        }
        // If still exceeded: continue — context/rules/identity/custom/summary/format are never trimmed
    }

    // Step 4 — assemble system content
    let formatInstruction = outputSpec.promptFormat.flatMap { formatInstructions[$0] }
    let systemContent = assembleSystemContent(
        context: context, profile: profile,
        profileMemories: profileMemories, dynamicMemory: dynamicMemory,
        formatInstruction: formatInstruction, conversationSummary: conversationSummary
    )

    // Step 5 — build message list
    var messages: [ChatMessage] = []

    if !systemContent.isEmpty {
        messages.append(ChatMessage(role: "system", content: systemContent))
    }

    if let session = session {
        // Replay window (spec 2.5.0 + 2.6.0). Skip turns folded into the summary;
        // optionally cap to the last N turns.
        var windowStart = summarizedThrough
        if let n = sessionContextTurns {
            windowStart = max(summarizedThrough, session.turns.count - max(0, n))
            // Snap down to a user turn so an odd-sized window never opens the replay
            // on an orphan assistant reply. Floored by summarizedThrough.
            while windowStart > summarizedThrough
                  && windowStart < session.turns.count
                  && session.turns[windowStart].role != .user {
                windowStart -= 1
            }
        }
        for turn in session.turns[windowStart...] {
            messages.append(ChatMessage(role: turn.role.rawValue, content: turn.content))
        }
    }

    var userParts = [prompt]
    for ctx in userContext where !ctx.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        userParts.append(ctx)
    }
    messages.append(ChatMessage(role: "user", content: userParts.joined(separator: sectionSeparator)))

    // Tool loop history for the current turn (spec 2.4.0). Appended after the
    // user message, never persisted in sessions.
    for turn in toolExchange {
        switch turn {
        case let .assistant(text, toolCalls, reasoning):
            messages.append(ChatMessage(
                role: "assistant",
                content: text ?? "",
                toolCalls: toolCalls,
                reasoning: reasoning
            ))
        case let .toolResult(toolCallId, name, content, _):
            messages.append(ChatMessage(role: "tool", content: content, toolCallId: toolCallId, name: name))
        }
    }

    return messages
}

// MARK: - Private helper

private func assembleSystemContent(
    context: [String],
    profile: Profile,
    profileMemories: [String],
    dynamicMemory: [String],
    formatInstruction: String?,
    conversationSummary: String? = nil
) -> String {
    var parts: [String] = []

    for ctx in context where !ctx.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        parts.append(ctx)
    }
    if !profile.rules.isEmpty    { parts.append(profile.rules) }
    if !profile.identity.isEmpty { parts.append(profile.identity) }
    if !profile.custom.isEmpty   { parts.append(profile.custom) }

    if !profileMemories.isEmpty {
        parts.append(memoriesHeader + profileMemories.joined(separator: memorySeparator))
    }
    if !dynamicMemory.isEmpty {
        parts.append(dynamicMemoryHeader + dynamicMemory.joined(separator: memorySeparator))
    }
    // Compaction summary (spec 2.5.0): after memory, before the format instruction.
    if let summary = conversationSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
        parts.append(summaryHeader + summary)
    }
    if let instr = formatInstruction {
        parts.append(instr)
    }

    return parts.joined(separator: sectionSeparator)
}
