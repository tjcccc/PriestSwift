# DEVLOG

## 2026-06-12 — v2.4.0 — tool calling, structured streaming (spec 2.4.0 sync)

Syncs the spec 2.4.0 features (reference: priest-typescript / Python priest-core 2.4.0).

- **Tool calling (caller executes):** `PriestRequest.tools` / `toolChoice` / `toolExchange`, `PriestResponse.toolCalls`, `FinishedReason.toolCalls`. Wire mappings for all three providers (OpenAI tools with JSON-string arguments, Anthropic tool_use/tool_result with merged user messages, Ollama tools with synthesized `call_N` ids and `tool_name` results). Tool exchange turns are never persisted in sessions.
- **`runWithTools()`:** generic call → execute → re-call loop with caller executor, optional `onToolCall` approval hook, iteration cap, and exchange trace.
- **`PriestEngine.streamEvents()`:** structured streaming (`text_delta`, `tool_call_start/delta/end`, `usage`, `done` with full `PriestResponse`); adapters without native event streaming fall back via the protocol extension; native streaming tool-call deltas are not yet surfaced by the built-in providers — use `run()` / `runWithTools()` for tool calling.
- **Breaking for adapter implementers:** provider messages changed from `[[String: String]]` to the new `ChatMessage` struct (which keeps a `["role"]`/`["content"]` subscript for read compatibility), and `complete`/`stream` gained an `options: AdapterCallOptions?` parameter.
- **Cancellation:** Swift maps the spec's cancellation concept to native Task cancellation; `requestAborted` and `imageLoadError` error codes added for table parity.
- `PriestEngine.specVersion` → "2.4.0". New tests in `ToolCallingTests`.

Known gap: multimodal `ImageInput` (spec 2.0) is still not implemented in this SDK.

---

## 2026-05-08 — v2.3.0 — optional profile memory loading

- Added `FilesystemProfileLoader(profilesRoot:includeMemories:)` so host apps can load profile identity/rules/custom files without injecting `memories/`
- When memory loading is disabled, `memories/*.md` and `*.txt` files are ignored and not tracked for cache invalidation
- Updated `PriestEngine.specVersion` to `2.3.0`

---

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

## 2026-04-12 — v1.0.0 release

- Added MIT LICENSE

## 2026-04-25 — v2.2.0 — json_schema structured output

Added `jsonSchema`, `jsonSchemaName`, and `jsonSchemaStrict` to `OutputSpec` (uses `[String: JSONValue]` for `Sendable` conformance).

- **OpenAI-compat:** `response_format:{type:"json_schema", json_schema:{name, schema, strict}}` in `buildPayload`.
- **Ollama (v0.5+):** `format:<schema_dict>` via `JSONValue.object(schema).toFoundation()`.
- **Anthropic:** schema description injected into system message in `buildPayload`; both `complete` and `stream` paths wired.
- `jsonSchemaStrict` defaults to `false`.
- Takes precedence over `providerFormat` when both are set.
- `PriestEngine.specVersion` → `"2.2.0"`

---

## 2026-04-20 — v2.0.0 — context API redesign, memory dedup/trim, profile cache

Breaking changes matching priest core v2.0.0 spec.

**Schema changes:**
- `PriestRequest.systemContext` → `context` (raw system context, passed through untouched)
- `PriestRequest.extraContext` → `userContext` (appended to user turn)
- `PriestRequest.memory` added — dynamic memory entries, deduped and trimmable
- `PriestConfig.maxSystemChars` added — triggers tail-trim when set

**Context assembly (`buildMessages`):**
- Dynamic memory rendered under `## Memory\n\n` heading (after `## Loaded Memories\n\n`)
- Dedup: whitespace-stripped comparison; drops any `memory` entry matching a profile memory or earlier dynamic entry
- Trim: tail-first on `memory`, then `profile.memories`; `context`/rules/identity/custom/format instructions never trimmed

**Profile loader cache:**
- `FilesystemProfileLoader` (struct) now caches loaded profiles per instance via a class-box (`Cache: @unchecked Sendable`)
- Cache key: `(maxMtime, fileCount)` across PROFILE.md, RULES.md, CUSTOM.md, profile.toml, memories/*
- Invalidates on any file change, addition, or removal

**Test suite:** 39 unit tests (up from ~29). New tests cover memory block rendering, cross-source dedup, self-dedup, whitespace-stripped dedup, tail-trim, and no-trim guard.

**Spec version:** `PriestEngine.specVersion` → `"2.0.0"`
