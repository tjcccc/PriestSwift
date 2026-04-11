# PriestSwift

Native Swift SDK for the [priest](https://github.com/tjcccc/priest) AI orchestration protocol.

iOS 15+ · macOS 12+ · Swift 5.9+ · Zero external dependencies

---

## Overview

PriestSwift is a Swift Package that implements the priest protocol spec v1.0.0 natively — no Python server, no FFI, no network dependency beyond the AI provider itself. It is designed for offline and on-device use cases: iOS apps, macOS tools, Unity (via .NET interop), and any Swift host.

The core API is two methods on `PriestEngine`:

| Method | Returns | Use when |
|--------|---------|----------|
| `run(_:)` | `PriestResponse` | You need structured metadata (usage, latency, session info) |
| `stream(_:)` | `AsyncThrowingStream<String, Error>` | You want to display text as it arrives |

---

## Installation

Add the package in Xcode: **File → Add Package Dependencies**, then enter the repository URL.

Or add it to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/tjcccc/PriestSwift", from: "0.1.0"),
],
targets: [
    .target(name: "YourTarget", dependencies: [
        .product(name: "Priest", package: "PriestSwift"),
    ]),
]
```

Then import:

```swift
import Priest
```

---

## Quick Start

### Single run with Ollama

```swift
import Priest

let engine = PriestEngine(
    profileLoader: FilesystemProfileLoader(baseURL: profilesDirectory),
    adapters: ["ollama": OllamaProvider(baseURL: URL(string: "http://localhost:11434")!)]
)

let request = PriestRequest(
    config: PriestConfig(provider: "ollama", model: "llama3.2"),
    prompt: "What is the capital of France?"
)

let response = try await engine.run(request)
if response.ok {
    print(response.text ?? "")
}
```

### Streaming

```swift
for try await chunk in engine.stream(request) {
    print(chunk, terminator: "")
}
```

### Using Anthropic or OpenAI-compatible providers

```swift
let engine = PriestEngine(
    profileLoader: FilesystemProfileLoader(baseURL: profilesDirectory),
    adapters: [
        "anthropic": AnthropicProvider(apiKey: "sk-ant-..."),
        "openai":    OpenAICompatProvider(baseURL: URL(string: "https://api.openai.com")!, apiKey: "sk-..."),
    ]
)

let request = PriestRequest(
    config: PriestConfig(provider: "anthropic", model: "claude-opus-4-6"),
    prompt: "Summarize the priest protocol in one sentence."
)
```

---

## Session Continuity

Pass a `SessionRef` to persist conversation history across calls.

```swift
let store = SQLiteSessionStore(path: dbURL)
try await store.open()

let engine = PriestEngine(
    profileLoader: ...,
    sessionStore: store,
    adapters: [...]
)

let sessionId = "user-123-chat"

// First turn — session is created automatically
let r1 = try await engine.run(PriestRequest(
    config: config,
    prompt: "My name is Alex.",
    session: SessionRef(id: sessionId)
))

// Second turn — session is continued
let r2 = try await engine.run(PriestRequest(
    config: config,
    prompt: "What is my name?",
    session: SessionRef(id: sessionId)
))
// r2.text → "Your name is Alex."
```

`SessionRef` behavior:

| `continueExisting` | `createIfMissing` | Result |
|--------------------|-------------------|--------|
| `true` (default) | `true` (default) | Load existing session or create it |
| `true` | `false` | Load existing or throw `.sessionNotFound` |
| `false` | — | Always create a new session |

The SQLite store is interoperable with the Python `priest` `SqliteSessionStore` — the schema and timestamp format are identical, so sessions written by Python can be read by Swift and vice versa.

---

## Profiles

A profile supplies `identity`, `rules`, and optional `custom` and `memories` sections that shape the system prompt.

```
profiles/
├── default.json      ← loaded when profile: "default"
└── coder.json        ← loaded when profile: "coder"
```

```swift
let loader = FilesystemProfileLoader(baseURL: URL(fileURLWithPath: "path/to/profiles"))
```

If the named profile file is not found, `FilesystemProfileLoader` falls back to the built-in default profile (a concise, honest assistant persona).

Profile format — `default.json`:

```json
{
  "identity": "You are a helpful assistant.",
  "rules": "Be honest. Do not make things up.\nBe concise unless the user asks for depth.",
  "custom": null,
  "memories": []
}
```

---

## Output Format Hints

```swift
// Ask the provider to return JSON natively (Ollama, OpenAI)
let request = PriestRequest(
    config: config,
    prompt: "List three planets as JSON.",
    output: OutputSpec(providerFormat: .json, promptFormat: .json)
)
```

`providerFormat` activates the provider's native structured-output mode (e.g. Ollama `format` field). `promptFormat` injects a natural-language instruction into the system prompt — it works with any provider.

`PriestResponse.text` is always the raw string. PriestSwift never parses the output.

---

## Error Handling

Two errors are always thrown as Swift exceptions and never captured into `response.error`:

- `.providerNotRegistered` — no adapter found for the requested provider key.
- `.sessionNotFound` — session lookup failed and `createIfMissing` is `false`.

All other provider errors (network failures, rate limits, timeouts) are caught and placed into `response.error`. Check `response.ok` before reading `response.text`.

```swift
do {
    let response = try await engine.run(request)
    if response.ok {
        print(response.text ?? "")
    } else {
        print("Provider error: \(response.error?.message ?? "unknown")")
    }
} catch let error as PriestError {
    // providerNotRegistered or sessionNotFound
    print("Fatal: \(error)")
}
```

---

## Providers

| Key | Type | Notes |
|-----|------|-------|
| `"ollama"` | `OllamaProvider` | NDJSON streaming; local by default |
| `"anthropic"` | `AnthropicProvider` | SSE streaming; requires API key |
| `"openai"` | `OpenAICompatProvider` | SSE streaming; works with any OpenAI-compatible endpoint |

Provider keys are arbitrary strings — the key you register in `adapters:` must match the `provider` field in `PriestConfig`.

---

## Spec

PriestSwift targets priest protocol spec **v1.0.0**. The spec lives in the [`priest`](https://github.com/tjcccc/priest) repository under `spec/`. It defines the canonical context assembly algorithm, session schema, timestamp format, and error codes that all priest SDKs must implement identically.

```swift
PriestEngine.specVersion  // "1.0.0"
```

---

## Requirements

- iOS 15+ / macOS 12+
- Swift 5.9+
- No external Swift package dependencies
