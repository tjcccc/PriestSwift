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
        let messages = buildMessages(profile: profile, session: nil, prompt: "Hi", systemContext: [], extraContext: [], outputSpec: .none)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"], "user")
    }

    func test_contextPriorityOrder() {
        let profile = makeProfile(identity: "IDENTITY", rules: "RULES")
        let messages = buildMessages(profile: profile, session: nil, prompt: "Hello", systemContext: ["SYS"], extraContext: [], outputSpec: .none)
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        // SYS must appear before RULES, RULES before IDENTITY
        XCTAssertLessThan(system.range(of: "SYS")!.lowerBound, system.range(of: "RULES")!.lowerBound)
        XCTAssertLessThan(system.range(of: "RULES")!.lowerBound, system.range(of: "IDENTITY")!.lowerBound)
    }

    func test_systemPartsSeparatedByDoubleNewline() {
        let profile = makeProfile(identity: "IDENTITY", rules: "RULES")
        let messages = buildMessages(profile: profile, session: nil, prompt: "Hi", systemContext: [], extraContext: [], outputSpec: .none)
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        XCTAssertTrue(system.contains("RULES\n\nIDENTITY"), "System parts must be joined with \\n\\n")
    }

    // MARK: - Format instructions (spec constants)

    func test_promptFormat_json() {
        let profile = makeProfile()
        let messages = buildMessages(profile: profile, session: nil, prompt: "Hi", systemContext: [], extraContext: [], outputSpec: OutputSpec(promptFormat: .json))
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        XCTAssertTrue(system.contains("Respond only with valid JSON. No prose, no markdown code fences."))
    }

    func test_promptFormat_xml() {
        let profile = makeProfile()
        let messages = buildMessages(profile: profile, session: nil, prompt: "Hi", systemContext: [], extraContext: [], outputSpec: OutputSpec(promptFormat: .xml))
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        XCTAssertTrue(system.contains("Respond only with valid XML. No prose, no markdown code fences."))
    }

    func test_promptFormat_code() {
        let profile = makeProfile()
        let messages = buildMessages(profile: profile, session: nil, prompt: "Hi", systemContext: [], extraContext: [], outputSpec: OutputSpec(promptFormat: .code))
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        XCTAssertTrue(system.contains("Respond only with code. No prose, no markdown code fences around it."))
    }

    // MARK: - Memory block

    func test_memoriesBlockHeader() {
        let profile = makeProfile(memories: ["Memory one.", "Memory two."])
        let messages = buildMessages(profile: profile, session: nil, prompt: "Hi", systemContext: [], extraContext: [], outputSpec: .none)
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        XCTAssertTrue(system.contains("## Loaded Memories\n\n"), "Memory block must use exact header")
    }

    func test_memoriesJoinedWithSingleNewline() {
        let profile = makeProfile(memories: ["Alpha.", "Beta."])
        let messages = buildMessages(profile: profile, session: nil, prompt: "Hi", systemContext: [], extraContext: [], outputSpec: .none)
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        // Memories joined with \n (single), not \n\n
        XCTAssertTrue(system.contains("Alpha.\nBeta."), "Memories must be joined with single newline")
        XCTAssertFalse(system.contains("Alpha.\n\nBeta."), "Memories must NOT be joined with double newline")
    }

    func test_emptyMemoriesIgnored() {
        let profile = makeProfile(memories: ["", "  ", "Real memory."])
        let messages = buildMessages(profile: profile, session: nil, prompt: "Hi", systemContext: [], extraContext: [], outputSpec: .none)
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        XCTAssertTrue(system.contains("Real memory."))
        XCTAssertFalse(system.contains("## Loaded Memories\n\n\n"))
    }

    // MARK: - Extra context

    func test_extraContextAppendedToUserMessage() {
        let profile = makeProfile()
        let messages = buildMessages(profile: profile, session: nil, prompt: "Prompt", systemContext: [], extraContext: ["Extra info"], outputSpec: .none)
        let user = messages.last(where: { $0["role"] == "user" })?["content"] ?? ""
        XCTAssertTrue(user.contains("Prompt"))
        XCTAssertTrue(user.contains("Extra info"))
        XCTAssertTrue(user.contains("Prompt\n\nExtra info"), "User parts must be joined with \\n\\n")
    }

    // MARK: - Session history

    func test_sessionTurnsInsertedBeforeUserMessage() {
        let session = Session(id: "s1", profileName: "test")
        session.appendTurn(role: .user, content: "Prior user turn")
        session.appendTurn(role: .assistant, content: "Prior assistant turn")

        let profile = makeProfile()
        let messages = buildMessages(profile: profile, session: session, prompt: "New prompt", systemContext: [], extraContext: [], outputSpec: .none)
        let roles = messages.map { $0["role"]! }
        // system, user (prior), assistant (prior), user (current)
        XCTAssertEqual(roles, ["system", "user", "assistant", "user"])
    }
}
