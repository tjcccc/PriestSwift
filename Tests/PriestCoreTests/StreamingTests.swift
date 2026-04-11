import XCTest
@testable import PriestCore

/// Tests for engine.stream() — chunk delivery, session persistence, error propagation.
final class StreamingTests: XCTestCase {

    private func makeEngine(store: (any SessionStore)? = nil, text: String = "hello world") -> PriestEngine {
        PriestEngine(
            profileLoader: FilesystemProfileLoader(),
            sessionStore: store,
            adapters: ["mock": MockStreamingAdapter(text: text)]
        )
    }

    private func makeRequest(overrides: (inout PriestRequest) -> Void = { _ in }) -> PriestRequest {
        var req = PriestRequest(
            config: PriestConfig(provider: "mock", model: "test-model"),
            prompt: "Say something."
        )
        overrides(&req)
        return req
    }

    // MARK: - Chunk delivery

    func test_streamYieldsChunks() async throws {
        let engine = makeEngine(text: "hello world foo")
        var chunks: [String] = []
        for try await chunk in engine.stream(makeRequest()) {
            chunks.append(chunk)
        }
        XCTAssertEqual(chunks, ["hello", "world", "foo"])
    }

    func test_streamReassemblesToFullText() async throws {
        let engine = makeEngine(text: "the quick brown fox")
        var parts: [String] = []
        for try await chunk in engine.stream(makeRequest()) {
            parts.append(chunk)
        }
        XCTAssertEqual(parts.joined(separator: " "), "the quick brown fox")
    }

    // MARK: - Session persistence

    func test_streamSavesSession() async throws {
        let store = InMemorySessionStore()
        let engine = makeEngine(store: store, text: "hello world")
        let req = makeRequest { $0.session = SessionRef(id: "stream-session", createIfMissing: true) }

        var chunks: [String] = []
        for try await chunk in engine.stream(req) { chunks.append(chunk) }

        let saved = try await store.get("stream-session")
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.turns.count, 2)
        XCTAssertEqual(saved?.turns[0].role, .user)
        XCTAssertEqual(saved?.turns[0].content, "Say something.")
        XCTAssertEqual(saved?.turns[1].role, .assistant)
        // Engine joins all chunks with "" — matches what was streamed
        XCTAssertEqual(saved?.turns[1].content, chunks.joined())
    }

    func test_streamSessionContinuesAcrossCalls() async throws {
        let store = InMemorySessionStore()
        let engine = makeEngine(store: store, text: "ok")

        for try await _ in engine.stream(makeRequest { $0.session = SessionRef(id: "multi", createIfMissing: true) }) {}
        for try await _ in engine.stream(makeRequest { $0.session = SessionRef(id: "multi", continueExisting: true) }) {}

        let saved = try await store.get("multi")
        XCTAssertEqual(saved?.turns.count, 4)
    }

    // MARK: - Error handling

    func test_streamUnknownProviderThrows() async throws {
        let engine = makeEngine()
        let req = makeRequest { $0.config = PriestConfig(provider: "unknown", model: "x") }
        do {
            for try await _ in engine.stream(req) {}
            XCTFail("Expected throw")
        } catch let e as PriestError {
            XCTAssertEqual(e.code, .providerNotRegistered)
        }
    }

    func test_streamWithoutSessionStoreStillYields() async throws {
        let engine = makeEngine(store: nil, text: "a b c")
        var chunks: [String] = []
        for try await chunk in engine.stream(makeRequest()) { chunks.append(chunk) }
        XCTAssertEqual(chunks, ["a", "b", "c"])
    }
}
