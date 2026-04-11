import Foundation
import SQLite3

// SQLITE_TRANSIENT is a C macro (-1 cast to destructor pointer) — not imported by Swift.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed session store.
///
/// Uses the canonical DDL and timestamp format from `behavior/session-lifecycle.md`
/// for cross-implementation interoperability with other priest SDKs.
///
/// Uses an actor for safe concurrent SQLite access.
public actor SQLiteSessionStore: SessionStore {
    private let path: URL
    private var db: OpaquePointer?

    // Timestamp format constants — must match spec exactly
    private static let writeFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
    private static let locale = Locale(identifier: "en_US_POSIX")
    private static let utc = TimeZone(abbreviation: "UTC")!

    public init(path: URL) {
        self.path = path
    }

    // MARK: - Lifecycle

    public func open() throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path.path, &db, flags, nil) == SQLITE_OK else {
            throw PriestError(code: .sessionStoreError, message: "Cannot open SQLite database at \(path.path)")
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS sessions (
                id           TEXT PRIMARY KEY,
                profile_name TEXT NOT NULL,
                created_at   TEXT NOT NULL,
                updated_at   TEXT NOT NULL,
                metadata     TEXT NOT NULL DEFAULT '{}'
            )
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS turns (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL REFERENCES sessions(id),
                role       TEXT NOT NULL,
                content    TEXT NOT NULL,
                timestamp  TEXT NOT NULL
            )
            """)
    }

    public func close() {
        if let db = db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    // MARK: - SessionStore

    public func create(profileName: String, sessionId: String? = nil, metadata: [String: JSONValue]? = nil) async throws -> Session {
        let id = sessionId ?? UUID().uuidString
        let now = Date()
        let session = Session(id: id, profileName: profileName, createdAt: now, updatedAt: now, metadata: metadata ?? [:])
        let metaJSON = encodeMetadata(session.metadata)
        try execStatement(
            "INSERT INTO sessions (id, profile_name, created_at, updated_at, metadata) VALUES (?, ?, ?, ?, ?)",
            params: [id, profileName, dtToStr(now), dtToStr(now), metaJSON]
        )
        return session
    }

    public func get(_ sessionId: String) async throws -> Session? {
        guard let db = db else { throw PriestError(code: .sessionStoreError, message: "Store not open") }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, profile_name, created_at, updated_at, metadata FROM sessions WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else {
            throw PriestError(code: .sessionStoreError, message: "Prepare failed: \(dbError())")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let id          = String(cString: sqlite3_column_text(stmt, 0))
        let profileName = String(cString: sqlite3_column_text(stmt, 1))
        let createdAt   = strToDt(String(cString: sqlite3_column_text(stmt, 2)))
        let updatedAt   = strToDt(String(cString: sqlite3_column_text(stmt, 3)))
        let metaStr     = String(cString: sqlite3_column_text(stmt, 4))
        let meta        = decodeMetadata(metaStr)

        let turns = try loadTurns(sessionId: id)
        return Session(id: id, profileName: profileName, createdAt: createdAt, updatedAt: updatedAt, turns: turns, metadata: meta)
    }

    public func save(_ session: Session) async throws {
        let metaJSON = encodeMetadata(session.metadata)
        try execStatement(
            "UPDATE sessions SET updated_at = ?, metadata = ? WHERE id = ?",
            params: [dtToStr(session.updatedAt), metaJSON, session.id]
        )
        try execStatement("DELETE FROM turns WHERE session_id = ?", params: [session.id])
        for turn in session.turns {
            try execStatement(
                "INSERT INTO turns (session_id, role, content, timestamp) VALUES (?, ?, ?, ?)",
                params: [session.id, turn.role.rawValue, turn.content, dtToStr(turn.timestamp)]
            )
        }
    }

    // MARK: - Helpers

    private func loadTurns(sessionId: String) throws -> [Turn] {
        guard let db = db else { throw PriestError(code: .sessionStoreError, message: "Store not open") }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT role, content, timestamp FROM turns WHERE session_id = ? ORDER BY id ASC", -1, &stmt, nil) == SQLITE_OK else {
            throw PriestError(code: .sessionStoreError, message: "Prepare failed: \(dbError())")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)

        var turns: [Turn] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let roleStr = String(cString: sqlite3_column_text(stmt, 0))
            let content = String(cString: sqlite3_column_text(stmt, 1))
            let tsStr   = String(cString: sqlite3_column_text(stmt, 2))
            let role    = Turn.Role(rawValue: roleStr) ?? .user
            turns.append(Turn(role: role, content: content, timestamp: strToDt(tsStr)))
        }
        return turns
    }

    private func exec(_ sql: String) throws {
        guard let db = db else { throw PriestError(code: .sessionStoreError, message: "Store not open") }
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw PriestError(code: .sessionStoreError, message: "SQLite error: \(msg)")
        }
    }

    private func execStatement(_ sql: String, params: [String]) throws {
        guard let db = db else { throw PriestError(code: .sessionStoreError, message: "Store not open") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw PriestError(code: .sessionStoreError, message: "Prepare failed: \(dbError())")
        }
        defer { sqlite3_finalize(stmt) }
        for (i, param) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), param, -1, SQLITE_TRANSIENT)
        }
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw PriestError(code: .sessionStoreError, message: "Step failed: \(dbError())")
        }
    }

    private func dbError() -> String {
        guard let db = db else { return "no db" }
        return String(cString: sqlite3_errmsg(db))
    }

    // MARK: - Timestamp

    private func dtToStr(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = SQLiteSessionStore.writeFormat
        fmt.locale = SQLiteSessionStore.locale
        fmt.timeZone = SQLiteSessionStore.utc
        return fmt.string(from: date)
    }

    private func strToDt(_ s: String) -> Date {
        // Try canonical format first, then fallback formats (lenient read per spec)
        let formats = [
            SQLiteSessionStore.writeFormat,
            "yyyy-MM-dd'T'HH:mm:ss'+00:00'",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'",
            "yyyy-MM-dd'T'HH:mm:ssZ",
        ]
        for format in formats {
            let fmt = DateFormatter()
            fmt.dateFormat = format
            fmt.locale = SQLiteSessionStore.locale
            fmt.timeZone = SQLiteSessionStore.utc
            if let date = fmt.date(from: s) { return date }
        }
        return Date()
    }

    // MARK: - Metadata encoding

    private func encodeMetadata(_ meta: [String: JSONValue]) -> String {
        guard let data = try? JSONEncoder().encode(meta),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    private func decodeMetadata(_ s: String) -> [String: JSONValue] {
        guard let data = s.data(using: .utf8),
              let meta = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return [:] }
        return meta
    }
}
