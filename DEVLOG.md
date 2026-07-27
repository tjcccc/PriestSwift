# DEVLOG

## 2026-07-27 — v2.8.0 — OpenAI Responses and provider-neutral reasoning

Syncs PriestSwift with protocol v2.8.0 and the TypeScript reference implementation.

- Added `OpenAIResponsesProvider` as a first-class `/v1/responses` adapter with complete and semantic SSE paths, structured output, function tools, deterministic finish/error mapping, usage details, and request-owned `model` / `input` / `stream` invariants.
- Added provider-neutral `ReasoningConfig`, safe `ReasoningInfo`, opaque continuation state, `reasoning_summary_delta`, `reasoningTokens`, and `contentFilter`.
- Mapped neutral reasoning controls to OpenAI Responses, Anthropic Messages, and Ollama. Anthropic now emits native structured reasoning/tool/usage stream events; Ollama rejects the unsupported `minimal` and `xhigh` effort values before transport.
- Preserved safe reasoning boundaries: raw chain-of-thought is never exposed, opaque signed/encrypted state is replayed only during tool exchanges, and reasoning state is not persisted in sessions.
- Preserved the SQLite schema, timestamp representation, and Python/TypeScript/.NET/Rust interoperability contract; no migration was introduced.
- Added focused v2.8 wire, parser, CRLF SSE, deduplication, safe-continuation, engine-stream, and tool-loop regression tests.
- `PriestEngine.specVersion` is now `"2.8.0"`. `swift test` passes 84 tests and `swift build -c release` passes.

## 2026-06-27 — v2.6.1 — full spec sync (compaction, turn window, cached tokens, streaming usage)

Brings PriestSwift to full parity with the spec at v2.6.1 (2.5.0 → 2.6.0 → 2.6.1), mirroring the priest-core/priest-typescript reference. All additions are off/opt-in by default; the SQLite schema is unchanged, so pre-2.5 sessions remain interoperable.

- **Cached input tokens (spec 2.5.0):** `AdapterResult.cachedInputTokens` / `UsageInfo.cachedInputTokens` and the `usage` stream event. Parsed from OpenAI-compat `usage.prompt_tokens_details.cached_tokens` and Anthropic `usage.cache_read_input_tokens`. Nil when omitted.
- **Conversation compaction (spec 2.5.0):** new `Engine/Compactor.swift` (`shouldCompact`, `planCompaction`, `buildSummaryMessages`; ratio 0.8, default keep 6, summary cap 1024). `PriestConfig.maxContextTokens` enables it; a chat turn crossing 80% of the budget folds older turns into a running summary and replays only `summary + recent tail`. State persists in session `metadata["__compaction"]` with **camelCase keys** (cross-SDK contract, `SessionModel.swift`). `engine.compactSession()` for a manual `/compact`; trigger measured on clean chat turns only (tool-exchange replays skipped).
- **Session turn window (spec 2.6.0):** `PriestConfig.sessionContextTurns` caps replayed turns; the context builder windows from `max(summarizedThrough, count-N)` and snaps an odd window down to a user turn.
- **OpenAI-compat streaming usage (spec 2.6.1):** streaming requests send `stream_options: {include_usage: true}` (overridable via `providerOptions`).
- **`streamEvents` promoted to a `ProviderAdapter` protocol requirement** (default impl unchanged in the extension) so adapters that surface native usage/tool-call events are dynamically dispatched — previously the extension default always shadowed overrides, so streaming never surfaced usage events.
- **Partial-parity caveat — streaming path:** compaction and cached-token reporting are **fully functional on `run()` / `complete()`**. On `stream()` / `streamEvents()` they are **inert in production**, because the shipping `OpenAICompatProvider` / `AnthropicProvider` do not override `streamEvents` (they wrap text-only `stream()`, a pre-existing collected-text streaming limitation) and so emit no `usage` event — without it the compaction trigger never records and `cachedInputTokens` is never seen. The engine wiring is correct and dispatches to any adapter that *does* emit native usage events (verified by `test_compactsOverStreamingPath` with a usage-emitting mock); surfacing native streaming usage in the real providers is a separate, larger change.
- `PriestEngine.specVersion` → "2.6.1"; README spec references bumped to v2.6.1.
- Tests: `Tests/PriestTests/CompactionTests.swift` (18 — incl. a SQLite round-trip asserting the persisted `__compaction` camelCase bytes) plus the existing wire tests. `swift test` green (75 total).

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
