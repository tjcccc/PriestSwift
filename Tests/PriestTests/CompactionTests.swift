import XCTest
import Foundation
@testable import Priest

/// Conversation compaction + session turn window (spec 2.5.0 / 2.6.0).
final class CompactionTests: XCTestCase {

    private static let summaryMarker = "compress prior conversation"

    private func isSummary(_ messages: [ChatMessage]) -> Bool {
        messages.first?.content.contains(Self.summaryMarker) ?? false
    }

    /// Thread-safe recorder of the messages arrays passed to the adapter.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[ChatMessage]] = []
        func add(_ m: [ChatMessage]) { lock.lock(); _calls.append(m); lock.unlock() }
        var calls: [[ChatMessage]] { lock.lock(); defer { lock.unlock() }; return _calls }
    }

    /// Reports a fixed input size on chat turns (to drive the trigger) and a short
    /// summary on the summarization call. Records every messages array.
    private final class ProgrammableAdapter: ProviderAdapter, @unchecked Sendable {
        let providerName = "mock"
        let inputTokens: Int
        let recorder: Recorder

        init(inputTokens: Int, recorder: Recorder) {
            self.inputTokens = inputTokens
            self.recorder = recorder
        }

        private func isSummary(_ messages: [ChatMessage]) -> Bool {
            messages.first?.content.contains("compress prior conversation") ?? false
        }

        func complete(messages: [ChatMessage], config: PriestConfig, outputSpec: OutputSpec, options: AdapterCallOptions? = nil) async throws -> AdapterResult {
            recorder.add(messages)
            let summary = isSummary(messages)
            return AdapterResult(
                text: summary ? "SUMMARY" : "assistant reply",
                finishReason: "stop",
                inputTokens: summary ? 5 : inputTokens,
                outputTokens: 5
            )
        }

        func streamEvents(messages: [ChatMessage], config: PriestConfig, outputSpec: OutputSpec, options: AdapterCallOptions?) -> AsyncThrowingStream<AdapterStreamEvent, Error> {
            recorder.add(messages)
            let tokens = inputTokens
            return AsyncThrowingStream { continuation in
                var textEvent = AdapterStreamEvent(type: "text_delta"); textEvent.text = "assistant reply"
                continuation.yield(textEvent)
                var usageEvent = AdapterStreamEvent(type: "usage"); usageEvent.inputTokens = tokens; usageEvent.outputTokens = 5
                continuation.yield(usageEvent)
                continuation.yield(AdapterStreamEvent(type: "finish"))
                continuation.finish()
            }
        }
    }

    private func budgetConfig() -> PriestConfig {
        var c = PriestConfig(provider: "mock", model: "test-model")
        c.maxContextTokens = 100
        c.compactionKeepTurns = 2
        return c
    }

    private func engine(store: any SessionStore, inputTokens: Int) -> (PriestEngine, Recorder) {
        let recorder = Recorder()
        let adapter = ProgrammableAdapter(inputTokens: inputTokens, recorder: recorder)
        let engine = PriestEngine(profileLoader: FilesystemProfileLoader(), sessionStore: store, adapters: ["mock": adapter])
        return (engine, recorder)
    }

    private func req(_ config: PriestConfig, _ prompt: String) -> PriestRequest {
        PriestRequest(config: config, prompt: prompt, session: SessionRef(id: "s"))
    }

    private func turn(_ role: Turn.Role, _ content: String) -> Turn {
        Turn(role: role, content: content)
    }

    // MARK: - Compactor (pure)

    func test_shouldCompact_offWithoutBudgetOrMeasuredTurn() {
        XCTAssertFalse(shouldCompact(lastInputTokens: 10_000, maxContextTokens: nil))
        XCTAssertFalse(shouldCompact(lastInputTokens: 10_000, maxContextTokens: 0))
        XCTAssertFalse(shouldCompact(lastInputTokens: nil, maxContextTokens: 1000))
    }

    func test_shouldCompact_firesOnlyAbove80Percent() {
        XCTAssertFalse(shouldCompact(lastInputTokens: 799, maxContextTokens: 1000))
        XCTAssertTrue(shouldCompact(lastInputTokens: 801, maxContextTokens: 1000))
    }

    func test_planCompaction_noneWhileHistoryFits() {
        let turns = [turn(.user, "a"), turn(.assistant, "b")]
        XCTAssertNil(planCompaction(turns: turns, alreadySummarizedThrough: 0, keepTurns: 2))
    }

    func test_planCompaction_foldsBeforeTailAndAdvances() {
        let turns = [turn(.user, "u1"), turn(.assistant, "a1"), turn(.user, "u2"), turn(.assistant, "a2")]
        let plan = planCompaction(turns: turns, alreadySummarizedThrough: 0, keepTurns: 2)
        XCTAssertEqual(plan?.summarizedThrough, 2)
        XCTAssertEqual(plan?.toSummarize.map(\.content), ["u1", "a1"])
    }

    func test_planCompaction_recursiveOnlyFoldsAfterSummarized() {
        let turns = [
            turn(.user, "u1"), turn(.assistant, "a1"),
            turn(.user, "u2"), turn(.assistant, "a2"),
            turn(.user, "u3"), turn(.assistant, "a3"),
        ]
        let plan = planCompaction(turns: turns, alreadySummarizedThrough: 2, keepTurns: 2)
        XCTAssertEqual(plan?.summarizedThrough, 4)
        XCTAssertEqual(plan?.toSummarize.map(\.content), ["u2", "a2"])
    }

    func test_buildSummaryMessages_mergesExistingAndIncludesNewTurns() {
        let messages = buildSummaryMessages(existingSummary: "prior synopsis", toSummarize: [turn(.user, "hello"), turn(.assistant, "hi there")])
        XCTAssertTrue(messages[0].content.contains(Self.summaryMarker))
        XCTAssertTrue(messages[1].content.contains("prior synopsis"))
        XCTAssertTrue(messages[1].content.contains("hello"))
        XCTAssertTrue(messages[1].content.contains("hi there"))
    }

    // MARK: - Engine compaction

    func test_compactsOverBudgetChatAndReplaysSummaryPlusTail() async throws {
        let store = InMemorySessionStore()
        let (eng, recorder) = engine(store: store, inputTokens: 200)

        for prompt in ["msg1", "msg2", "msg3"] {
            _ = try await eng.run(req(budgetConfig(), prompt))
        }

        let session = try await store.get("s")
        XCTAssertEqual(session?.getCompaction().summary, "SUMMARY")
        XCTAssertTrue(recorder.calls.contains(where: isSummary))

        let lastChat = recorder.calls.last(where: { !isSummary($0) })!
        XCTAssertTrue(lastChat[0].content.contains("## Conversation so far (summary)"))
        XCTAssertTrue(lastChat[0].content.contains("SUMMARY"))
        XCTAssertFalse(lastChat.contains(where: { $0.content == "msg1" }))
    }

    func test_compactionStateSurvivesSqliteRoundTrip() async throws {
        // Cross-SDK interop: state written as camelCase JSON must read back from a
        // fresh store, and the persisted bytes must use camelCase keys.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("sessions.db")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SQLiteSessionStore(path: dbURL)
        try await store.open()
        let (eng, _) = engine(store: store, inputTokens: 200)
        for prompt in ["msg1", "msg2", "msg3"] {
            _ = try await eng.run(req(budgetConfig(), prompt))
        }

        // Reopen a fresh store on the same DB — forces a JSON deserialize.
        let fresh = SQLiteSessionStore(path: dbURL)
        try await fresh.open()
        let session = try await fresh.get("s")
        let comp = session!.getCompaction()
        XCTAssertEqual(comp.summary, "SUMMARY")
        XCTAssertEqual(comp.summarizedThrough, 2)

        // Assert on the persisted bytes: camelCase only, no snake_case leak.
        let raw = session!.metadata[Session.compactionMetadataKey]!
        let data = try JSONSerialization.data(withJSONObject: raw.toFoundation())
        let serialized = String(data: data, encoding: .utf8)!
        XCTAssertTrue(serialized.contains("summarizedThrough"))
        XCTAssertFalse(serialized.contains("summarized_through"))
    }

    func test_doesNotRecordTriggerWhenToolExchangeReplayed() async throws {
        let store = InMemorySessionStore()
        let (eng, _) = engine(store: store, inputTokens: 200)

        var request = req(budgetConfig(), "msg1")
        request.toolExchange = [.toolResult(toolCallId: "c1", name: "web_search", content: "big results")]
        _ = try await eng.run(request)

        let session = try await store.get("s")
        XCTAssertNil(session?.getCompaction().lastInputTokens)
    }

    /// Validates the engine streaming plumbing (maybeCompact + recordChatUsage)
    /// using an adapter that emits a native `usage` event. NOTE: the shipping
    /// `OpenAICompatProvider`/`AnthropicProvider` do NOT override `streamEvents`
    /// (they wrap text-only `stream()`), so production streaming surfaces no usage
    /// — streaming-path compaction is currently inert for those providers. See DEVLOG.
    func test_compactsOverStreamingPath() async throws {
        let store = InMemorySessionStore()
        let (eng, _) = engine(store: store, inputTokens: 200)

        for prompt in ["msg1", "msg2", "msg3"] {
            for try await _ in eng.streamEvents(req(budgetConfig(), prompt)) {}
        }

        let session = try await store.get("s")
        XCTAssertEqual(session?.getCompaction().summary, "SUMMARY")
    }

    func test_neverCompactsWithoutBudget() async throws {
        let store = InMemorySessionStore()
        let (eng, recorder) = engine(store: store, inputTokens: 200)
        let noBudget = PriestConfig(provider: "mock", model: "test-model")

        for prompt in ["msg1", "msg2", "msg3", "msg4"] {
            _ = try await eng.run(req(noBudget, prompt))
        }

        let session = try await store.get("s")
        XCTAssertNil(session?.getCompaction().summary)
        XCTAssertFalse(recorder.calls.contains(where: isSummary))
    }

    func test_compactSessionFoldsOnDemandAndReportsCoverage() async throws {
        let store = InMemorySessionStore()
        let (eng, _) = engine(store: store, inputTokens: 10) // small input — no auto-compaction
        let noBudget = PriestConfig(provider: "mock", model: "test-model")

        for prompt in ["msg1", "msg2", "msg3"] {
            _ = try await eng.run(req(noBudget, prompt))
        }
        let before = try await store.get("s")
        XCTAssertNil(before?.getCompaction().summary)

        var config = PriestConfig(provider: "mock", model: "test-model")
        config.compactionKeepTurns = 2
        let result = try await eng.compactSession("s", config: config)
        XCTAssertTrue(result.compacted)
        XCTAssertEqual(result.summarizedThrough, 4) // 6 turns − keep 2
        let after = try await store.get("s")
        XCTAssertEqual(after?.getCompaction().summary, "SUMMARY")
    }

    func test_compactSessionThrowsForUnknownSession() async throws {
        let store = InMemorySessionStore()
        let (eng, _) = engine(store: store, inputTokens: 10)
        do {
            _ = try await eng.compactSession("nope", config: PriestConfig(provider: "mock", model: "m"))
            XCTFail("expected sessionNotFound")
        } catch let error as PriestError {
            XCTAssertEqual(error.code, .sessionNotFound)
        }
    }

    // MARK: - Session turn window (spec 2.6.0)

    private let windowProfile = Profile(name: "default", identity: "")

    private func sessionWith(_ n: Int) -> Session {
        let session = Session(id: "s", profileName: "default")
        for i in 0..<n {
            session.appendTurn(role: i % 2 == 0 ? .user : .assistant, content: "turn-\(i)")
        }
        return session
    }

    private func replayed(_ msgs: [ChatMessage]) -> [String] {
        let body = msgs.filter { $0.role != "system" }
        return body.dropLast().map(\.content)
    }

    func test_replaysAllTurnsWhenWindowUnset() {
        let msgs = buildMessages(profile: windowProfile, session: sessionWith(6), prompt: "Hi", context: [], memory: [], userContext: [], outputSpec: OutputSpec())
        XCTAssertEqual(replayed(msgs), ["turn-0", "turn-1", "turn-2", "turn-3", "turn-4", "turn-5"])
    }

    func test_replaysOnlyLastNTurns() {
        let msgs = buildMessages(profile: windowProfile, session: sessionWith(6), prompt: "Hi", context: [], memory: [], userContext: [], outputSpec: OutputSpec(), sessionContextTurns: 2)
        XCTAssertEqual(replayed(msgs), ["turn-4", "turn-5"])
    }

    func test_replaysNoTurnsWhenWindowIsZero() {
        let msgs = buildMessages(profile: windowProfile, session: sessionWith(6), prompt: "Hi", context: [], memory: [], userContext: [], outputSpec: OutputSpec(), sessionContextTurns: 0)
        XCTAssertTrue(replayed(msgs).isEmpty)
    }

    func test_snapsOddWindowDownToUserTurn() {
        let msgs = buildMessages(profile: windowProfile, session: sessionWith(8), prompt: "Hi", context: [], memory: [], userContext: [], outputSpec: OutputSpec(), sessionContextTurns: 5)
        XCTAssertEqual(msgs.first(where: { $0.role != "system" })?.role, "user")
        XCTAssertEqual(replayed(msgs), ["turn-2", "turn-3", "turn-4", "turn-5", "turn-6", "turn-7"])
    }

    func test_windowNeverUnhidesSummarizedTurns() {
        let session = sessionWith(6)
        session.applyCompaction(summary: "earlier conversation summary", summarizedThrough: 4)
        let msgs = buildMessages(profile: windowProfile, session: session, prompt: "Hi", context: [], memory: [], userContext: [], outputSpec: OutputSpec(), sessionContextTurns: 5)
        XCTAssertEqual(replayed(msgs), ["turn-4", "turn-5"])
        XCTAssertTrue(msgs[0].content.contains("earlier conversation summary"))
    }
}
