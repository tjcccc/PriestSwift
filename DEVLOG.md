# DEVLOG

## 2026-04-11 — Initial implementation

First implementation of `PriestSwift`, a native Swift Package for iOS (15+) and macOS (12+).

Implements the priest protocol spec v1.0.0. Reference implementation: Python `priest-core`.

**What's implemented:**
- All three providers: Ollama (NDJSON streaming), OpenAI-compatible (SSE streaming), Anthropic (SSE streaming)
- Session persistence: `InMemorySessionStore` (actor) + `SQLiteSessionStore` (actor, sqlite3 C API)
- Profile loading: `FilesystemProfileLoader` + built-in default profile
- Context assembly: `buildMessages()` — mirrors `context_builder.py` exactly
- `PriestEngine.run()` and `stream()` — full spec-compliant implementations
- Error types: `PriestError` struct + `PriestErrorCode` enum (rawValues match spec)
- Schema types: all request/response types as value types (structs); `Session` as class
- `JSONValue` indirect enum for heterogeneous JSON without external dependencies

**Zero external dependencies** — URLSession for HTTP, sqlite3 C API for persistence, Foundation only.

**Test suite:** ContextBuilderTests, EngineTests, StreamingTests, SessionStoreTests.

**Spec version targeted:** 1.0.0 (asserted in `PriestEngine.specVersion`).
