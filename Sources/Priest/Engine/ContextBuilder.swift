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
    maxSystemChars: Int? = nil
) -> [[String: String]] {

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
                                    dynamicMemory: dynamicMemory, formatInstruction: fmtStr).count > budget {
            dynamicMemory.removeLast()
        }
        while !profileMemories.isEmpty &&
              assembleSystemContent(context: context, profile: profile, profileMemories: profileMemories,
                                    dynamicMemory: dynamicMemory, formatInstruction: fmtStr).count > budget {
            profileMemories.removeLast()
        }
        // If still exceeded: continue — context/rules/identity/custom/format are never trimmed
    }

    // Step 4 — assemble system content
    let formatInstruction = outputSpec.promptFormat.flatMap { formatInstructions[$0] }
    let systemContent = assembleSystemContent(
        context: context, profile: profile,
        profileMemories: profileMemories, dynamicMemory: dynamicMemory,
        formatInstruction: formatInstruction
    )

    // Step 5 — build message list
    var messages: [[String: String]] = []

    if !systemContent.isEmpty {
        messages.append(["role": "system", "content": systemContent])
    }

    if let session = session {
        for turn in session.turns {
            messages.append(["role": turn.role.rawValue, "content": turn.content])
        }
    }

    var userParts = [prompt]
    for ctx in userContext where !ctx.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        userParts.append(ctx)
    }
    messages.append(["role": "user", "content": userParts.joined(separator: sectionSeparator)])

    return messages
}

// MARK: - Private helper

private func assembleSystemContent(
    context: [String],
    profile: Profile,
    profileMemories: [String],
    dynamicMemory: [String],
    formatInstruction: String?
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
    if let instr = formatInstruction {
        parts.append(instr)
    }

    return parts.joined(separator: sectionSeparator)
}
