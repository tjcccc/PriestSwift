import XCTest
@testable import Priest

/// Tests for the context assembly algorithm.
/// Verifies canonical string constants and assembly order.
final class ContextBuilderTests: XCTestCase {

    private func makeProfile(
        identity: String = "You are a bot.",
        rules: String = "Be concise.",
        custom: String = "",
        memories: [String] = []
    ) -> Profile {
        Profile(name: "test", identity: identity, rules: rules, custom: custom, memories: memories)
    }

    // MARK: - Basic assembly

    func test_systemMessageNotAddedWhenEmpty() {
        let profile = Profile(name: "test", identity: "", rules: "", custom: "", memories: [])
        let messages = buildMessages(profile: profile, session: nil, prompt: "Hi",
                                     context: [], memory: [], userContext: [], outputSpec: .none)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"], "user")
    }

    func test_contextPriorityOrder() {
        let profile = makeProfile(identity: "IDENTITY", rules: "RULES")
        let messages = buildMessages(profile: profile, session: nil, prompt: "Hello",
                                     context: ["SYS"], memory: [], userContext: [], outputSpec: .none)
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        XCTAssertLessThan(system.range(of: "SYS")!.lowerBound, system.range(of: "RULES")!.lowerBound)
        XCTAssertLessThan(system.range(of: "RULES")!.lowerBound, system.range(of: "IDENTITY")!.lowerBound)
    }

    func test_systemPartsSeparatedByDoubleNewline() {
        let profile = makeProfile(identity: "IDENTITY", rules: "RULES")
        let messages = buildMessages(profile: profile, session: nil, prompt: "Hi",
                                     context: [], memory: [], userContext: [], outputSpec: .none)
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        XCTAssertTrue(system.contains("RULES\n\nIDENTITY"), "System parts must be joined with \\n\\n")
    }

    // MARK: - Format instructions (spec constants)

    func test_promptFormat_json() {
        let messages = buildMessages(profile: makeProfile(), session: nil, prompt: "Hi",
                                     context: [], memory: [], userContext: [],
                                     outputSpec: OutputSpec(promptFormat: .json))
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        XCTAssertTrue(system.contains("Respond only with valid JSON. No prose, no markdown code fences."))
    }

    func test_promptFormat_xml() {
        let messages = buildMessages(profile: makeProfile(), session: nil, prompt: "Hi",
                                     context: [], memory: [], userContext: [],
                                     outputSpec: OutputSpec(promptFormat: .xml))
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        XCTAssertTrue(system.contains("Respond only with valid XML. No prose, no markdown code fences."))
    }

    func test_promptFormat_code() {
        let messages = buildMessages(profile: makeProfile(), session: nil, prompt: "Hi",
                                     context: [], memory: [], userContext: [],
                                     outputSpec: OutputSpec(promptFormat: .code))
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        XCTAssertTrue(system.contains("Respond only with code. No prose, no markdown code fences around it."))
    }

    // MARK: - Profile memory block

    func test_memoriesBlockHeader() {
        let profile = makeProfile(memories: ["Memory one.", "Memory two."])
        let messages = buildMessages(profile: profile, session: nil, prompt: "Hi",
                                     context: [], memory: [], userContext: [], outputSpec: .none)
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        XCTAssertTrue(system.contains("## Loaded Memories\n\n"), "Memory block must use exact header")
    }

    func test_memoriesJoinedWithSingleNewline() {
        let profile = makeProfile(memories: ["Alpha.", "Beta."])
        let messages = buildMessages(profile: profile, session: nil, prompt: "Hi",
                                     context: [], memory: [], userContext: [], outputSpec: .none)
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        XCTAssertTrue(system.contains("Alpha.\nBeta."), "Memories must be joined with single newline")
        XCTAssertFalse(system.contains("Alpha.\n\nBeta."), "Memories must NOT be joined with double newline")
    }

    func test_emptyMemoriesIgnored() {
        let profile = makeProfile(memories: ["", "  ", "Real memory."])
        let messages = buildMessages(profile: profile, session: nil, prompt: "Hi",
                                     context: [], memory: [], userContext: [], outputSpec: .none)
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        XCTAssertTrue(system.contains("Real memory."))
        XCTAssertFalse(system.contains("## Loaded Memories\n\n\n"))
    }

    // MARK: - User context

    func test_userContextAppendedToUserMessage() {
        let messages = buildMessages(profile: makeProfile(), session: nil, prompt: "Prompt",
                                     context: [], memory: [], userContext: ["Extra info"], outputSpec: .none)
        let user = messages.last(where: { $0["role"] == "user" })?["content"] ?? ""
        XCTAssertTrue(user.contains("Prompt\n\nExtra info"), "User parts must be joined with \\n\\n")
    }

    // MARK: - Session history

    func test_sessionTurnsInsertedBeforeUserMessage() {
        let session = Session(id: "s1", profileName: "test")
        session.appendTurn(role: .user, content: "Prior user turn")
        session.appendTurn(role: .assistant, content: "Prior assistant turn")

        let messages = buildMessages(profile: makeProfile(), session: session, prompt: "New prompt",
                                     context: [], memory: [], userContext: [], outputSpec: .none)
        let roles = messages.map { $0["role"]! }
        XCTAssertEqual(roles, ["system", "user", "assistant", "user"])
    }

    // MARK: - v2.0.0 dynamic memory block

    func test_dynamicMemoryRenderedUnderMemoryHeader() {
        let messages = buildMessages(profile: makeProfile(), session: nil, prompt: "Hi",
                                     context: [], memory: ["User prefers dark mode."],
                                     userContext: [], outputSpec: .none)
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        XCTAssertTrue(system.contains("## Memory\n\nUser prefers dark mode."))
    }

    func test_profileMemoriesBeforeDynamicMemory() {
        let profile = makeProfile(memories: ["Static fact."])
        let messages = buildMessages(profile: profile, session: nil, prompt: "Hi",
                                     context: [], memory: ["Dynamic fact."],
                                     userContext: [], outputSpec: .none)
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        let loadedIdx = system.range(of: "## Loaded Memories")!.lowerBound
        let memIdx    = system.range(of: "## Memory")!.lowerBound
        XCTAssertLessThan(loadedIdx, memIdx)
    }

    // MARK: - v2.0.0 deduplication

    func test_dynamicMemoryDuplicatingProfileMemoryIsDropped() {
        let profile = makeProfile(memories: ["Fact A."])
        let messages = buildMessages(profile: profile, session: nil, prompt: "Hi",
                                     context: [], memory: ["Fact A.", "Fact B."],
                                     userContext: [], outputSpec: .none)
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        let first  = system.range(of: "Fact A.")!.lowerBound
        XCTAssertNil(system.range(of: "Fact A.", range: system.index(after: first)..<system.endIndex))
        XCTAssertTrue(system.contains("Fact B."))
    }

    func test_duplicateDynamicMemoryEntriesAreDropped() {
        let messages = buildMessages(profile: makeProfile(), session: nil, prompt: "Hi",
                                     context: [], memory: ["Note X.", "Note X."],
                                     userContext: [], outputSpec: .none)
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        let first  = system.range(of: "Note X.")!.lowerBound
        XCTAssertNil(system.range(of: "Note X.", range: system.index(after: first)..<system.endIndex))
    }

    func test_deduplicationStripsWhitespace() {
        let profile = makeProfile(memories: ["Fact A."])
        let messages = buildMessages(profile: profile, session: nil, prompt: "Hi",
                                     context: [], memory: ["  Fact A.  "],
                                     userContext: [], outputSpec: .none)
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        XCTAssertFalse(system.contains("## Memory"))
    }

    // MARK: - v2.0.0 trim

    func test_trimsDynamicMemoryTailFirstWhenBudgetExceeded() {
        let profile = Profile(name: "p", identity: "", rules: "", custom: "", memories: [])
        let messages = buildMessages(profile: profile, session: nil, prompt: "Hi",
                                     context: [], memory: ["Short.", String(repeating: "X", count: 500)],
                                     userContext: [], outputSpec: .none, maxSystemChars: 50)
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        XCTAssertTrue(system.contains("Short."))
        XCTAssertFalse(system.contains(String(repeating: "X", count: 500)))
    }

    func test_noTrimWhenMaxSystemCharsNotSet() {
        let profile = Profile(name: "p", identity: "", rules: "", custom: "", memories: [])
        let messages = buildMessages(profile: profile, session: nil, prompt: "Hi",
                                     context: [], memory: ["A.", "B.", "C."],
                                     userContext: [], outputSpec: .none)
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        XCTAssertTrue(system.contains("A."))
        XCTAssertTrue(system.contains("B."))
        XCTAssertTrue(system.contains("C."))
    }
}
