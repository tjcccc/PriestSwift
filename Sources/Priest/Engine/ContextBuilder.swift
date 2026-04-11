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

private let memoriesHeader  = "## Loaded Memories\n\n"
private let sectionSeparator = "\n\n"      // between system parts and between user parts
private let memorySeparator  = "\n"        // between individual memory file contents

// MARK: - Assembly

func buildMessages(
    profile: Profile,
    session: Session?,
    prompt: String,
    systemContext: [String],
    extraContext: [String],
    outputSpec: OutputSpec
) -> [[String: String]] {

    // Step 1 — Build system parts list
    var systemParts: [String] = []

    for ctx in systemContext where !ctx.isEmpty {
        systemParts.append(ctx)
    }
    if !profile.rules.isEmpty    { systemParts.append(profile.rules) }
    if !profile.identity.isEmpty { systemParts.append(profile.identity) }
    if !profile.custom.isEmpty   { systemParts.append(profile.custom) }

    let nonEmptyMemories = profile.memories.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    if !nonEmptyMemories.isEmpty {
        let memoryBlock = memoriesHeader + nonEmptyMemories.joined(separator: memorySeparator)
        systemParts.append(memoryBlock)
    }

    if let format = outputSpec.promptFormat, let instruction = formatInstructions[format] {
        systemParts.append(instruction)
    }

    // Step 2 — Build message list
    var messages: [[String: String]] = []

    if !systemParts.isEmpty {
        messages.append(["role": "system", "content": systemParts.joined(separator: sectionSeparator)])
    }

    if let session = session {
        for turn in session.turns {
            messages.append(["role": turn.role.rawValue, "content": turn.content])
        }
    }

    var userParts = [prompt]
    for ctx in extraContext where !ctx.isEmpty {
        userParts.append(ctx)
    }
    messages.append(["role": "user", "content": userParts.joined(separator: sectionSeparator)])

    return messages
}
