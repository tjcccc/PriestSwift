import XCTest
@testable import PriestCore

/// Engine unit tests — mirrors test_engine.py test cases.
final class EngineTests: XCTestCase {

    private func makeEngine(store: (any SessionStore)? = nil, text: String = "hello") -> PriestEngine {
        PriestEngine(
            profileLoader: FilesystemProfileLoader(),  // falls back to built-in default
            sessionStore: store,
            adapters: ["mock": MockAdapter(text: text)]
        )
    }

    private func makeRequest(overrides: (inout PriestRequest) -> Void = { _ in }) -> PriestRequest {
        var req = PriestRequest(
            config: PriestConfig(provider: "mock", model: "test-model"),
            prompt: "Say hello."
        )
        overrides(&req)
        return req
    }

    // MARK: - Basic run

    func test_basicRunReturnsResponse() async throws {
        let response = try await makeEngine().run(makeRequest())
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.text, "hello")
        XCTAssertEqual(response.execution.provider, "mock")
        XCTAssertEqual(response.execution.model, "test-model")
        XCTAssertEqual(response.execution.profile, "default")
        XCTAssertEqual(response.execution.finishedReason, .stop)
        XCTAssertNotNil(response.usage)
        XCTAssertEqual(response.usage?.inputTokens, 10)
        XCTAssertEqual(response.usage?.outputTokens, 5)
        XCTAssertEqual(response.usage?.totalTokens, 15)
        XCTAssertNil(response.session)
    }

    func test_unknownProviderThrows() async throws {
        let req = makeRequest { $0.config = PriestConfig(provider: "unknown", model: "x") }
        do {
            _ = try await makeEngine().run(req)
            XCTFail("Expected throw")
        } catch let e as PriestError {
            XCTAssertEqual(e.code, .providerNotRegistered)
        }
    }

    func test_metadataEchoed() async throws {
        let req = makeRequest { $0.metadata = ["req_id": "abc123"] }
        let response = try await makeEngine().run(req)
        XCTAssertEqual(response.metadata["req_id"], "abc123")
    }

    // MARK: - Sessions

    func test_sessionCreatedWithCallerId() async throws {
        let store = InMemorySessionStore()
        let engine = PriestEngine(
            profileLoader: FilesystemProfileLoader(),
            sessionStore: store,
            adapters: ["mock": MockAdapter()]
        )
        let req = makeRequest { $0.session = SessionRef(id: "my-session", createIfMissing: true) }
        let response = try await engine.run(req)

        XCTAssertNotNil(response.session)
        XCTAssertEqual(response.session?.id, "my-session")
        XCTAssertEqual(response.session?.isNew, true)
        XCTAssertEqual(response.session?.turnCount, 2)

        let saved = try await store.get("my-session")
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.turns.count, 2)
        XCTAssertEqual(saved?.turns[0].role, .user)
        XCTAssertEqual(saved?.turns[1].role, .assistant)
    }

    func test_sessionContinuedAcrossRuns() async throws {
        let store = InMemorySessionStore()
        let engine = PriestEngine(
            profileLoader: FilesystemProfileLoader(),
            sessionStore: store,
            adapters: ["mock": MockAdapter()]
        )

        let r1 = try await engine.run(makeRequest { $0.session = SessionRef(id: "s1", createIfMissing: true) })
        XCTAssertEqual(r1.session?.id, "s1")

        let r2 = try await engine.run(makeRequest { $0.session = SessionRef(id: "s1", continueExisting: true) })
        XCTAssertEqual(r2.session?.isNew, false)
        XCTAssertEqual(r2.session?.turnCount, 4)
    }

    // MARK: - Output format

    func test_jsonFormatReturnsRawText() async throws {
        let engine = makeEngine(text: "{\"answer\": 42}")
        let req = makeRequest { $0.output = OutputSpec(providerFormat: .json) }
        let response = try await engine.run(req)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.text, "{\"answer\": 42}")
    }

    // MARK: - Spec version

    func test_specVersion() {
        XCTAssertEqual(PriestEngine.specVersion, "1.0.0")
    }
}
