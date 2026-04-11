import XCTest
@testable import Priest

final class SessionStoreTests: XCTestCase {

    // MARK: - InMemorySessionStore

    func test_inMemory_createAndGet() async throws {
        let store = InMemorySessionStore()
        let session = try await store.create(profileName: "default", sessionId: "s1", metadata: nil)
        XCTAssertEqual(session.id, "s1")
        XCTAssertEqual(session.profileName, "default")

        let loaded = try await store.get("s1")
        XCTAssertEqual(loaded?.id, "s1")
    }

    func test_inMemory_getMissingReturnsNil() async throws {
        let store = InMemorySessionStore()
        let result = try await store.get("nonexistent")
        XCTAssertNil(result)
    }

    func test_inMemory_savePersistsTurns() async throws {
        let store = InMemorySessionStore()
        let session = try await store.create(profileName: "default", sessionId: "s1", metadata: nil)
        session.appendTurn(role: .user, content: "Hello")
        session.appendTurn(role: .assistant, content: "Hi there")
        try await store.save(session)

        let loaded = try await store.get("s1")
        XCTAssertEqual(loaded?.turns.count, 2)
        XCTAssertEqual(loaded?.turns[0].content, "Hello")
        XCTAssertEqual(loaded?.turns[1].content, "Hi there")
    }

    func test_inMemory_generateIdWhenNil() async throws {
        let store = InMemorySessionStore()
        let session = try await store.create(profileName: "default", sessionId: nil, metadata: nil)
        XCTAssertFalse(session.id.isEmpty)
    }

    // MARK: - SQLiteSessionStore

    private func makeTempStore() -> SQLiteSessionStore {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("priest_test_\(UUID().uuidString).db")
        return SQLiteSessionStore(path: tmp)
    }

    func test_sqlite_createAndGet() async throws {
        let store = makeTempStore()
        try await store.open()
        defer { Task { await store.close() } }

        let session = try await store.create(profileName: "default", sessionId: "s1", metadata: nil)
        XCTAssertEqual(session.id, "s1")

        let loaded = try await store.get("s1")
        XCTAssertEqual(loaded?.id, "s1")
        XCTAssertEqual(loaded?.profileName, "default")
    }

    func test_sqlite_getMissingReturnsNil() async throws {
        let store = makeTempStore()
        try await store.open()
        defer { Task { await store.close() } }

        let result = try await store.get("missing")
        XCTAssertNil(result)
    }

    func test_sqlite_savePersistsTurns() async throws {
        let store = makeTempStore()
        try await store.open()
        defer { Task { await store.close() } }

        let session = try await store.create(profileName: "default", sessionId: "s1", metadata: nil)
        session.appendTurn(role: .user, content: "Hello")
        session.appendTurn(role: .assistant, content: "Hi")
        try await store.save(session)

        let loaded = try await store.get("s1")
        XCTAssertEqual(loaded?.turns.count, 2)
        XCTAssertEqual(loaded?.turns[0].role, .user)
        XCTAssertEqual(loaded?.turns[0].content, "Hello")
        XCTAssertEqual(loaded?.turns[1].role, .assistant)
        XCTAssertEqual(loaded?.turns[1].content, "Hi")
    }

    func test_sqlite_turnsOrderedByInsertionOrder() async throws {
        let store = makeTempStore()
        try await store.open()
        defer { Task { await store.close() } }

        let session = try await store.create(profileName: "default", sessionId: "s1", metadata: nil)
        for i in 0..<5 {
            session.appendTurn(role: .user, content: "msg\(i)")
        }
        try await store.save(session)

        let loaded = try await store.get("s1")
        let contents = loaded?.turns.map { $0.content } ?? []
        XCTAssertEqual(contents, ["msg0", "msg1", "msg2", "msg3", "msg4"])
    }
}
