import Foundation
@testable import Priest

/// Fake provider adapter for unit tests — no network calls.
final class MockAdapter: ProviderAdapter {
    let providerName = "mock"
    let text: String
    let finishReason: String

    init(text: String = "hello", finishReason: String = "stop") {
        self.text = text
        self.finishReason = finishReason
    }

    func complete(messages: [ChatMessage], config: PriestConfig, outputSpec: OutputSpec, options: AdapterCallOptions? = nil) async throws -> AdapterResult {
        AdapterResult(text: text, finishReason: finishReason, inputTokens: 10, outputTokens: 5)
    }

    // stream() uses the default extension: calls complete() and yields full text as one chunk.
}

/// Streaming mock that yields text one word at a time (no spaces).
final class MockStreamingAdapter: ProviderAdapter {
    let providerName = "mock"
    let text: String

    init(text: String = "hello world") {
        self.text = text
    }

    func complete(messages: [ChatMessage], config: PriestConfig, outputSpec: OutputSpec, options: AdapterCallOptions? = nil) async throws -> AdapterResult {
        AdapterResult(text: text, finishReason: "stop", inputTokens: 10, outputTokens: 5)
    }

    func stream(messages: [ChatMessage], config: PriestConfig, outputSpec: OutputSpec, options: AdapterCallOptions? = nil) -> AsyncThrowingStream<String, Error> {
        let words = text.split(separator: " ").map(String.init)
        return AsyncThrowingStream { continuation in
            Task {
                for word in words { continuation.yield(word) }
                continuation.finish()
            }
        }
    }
}


/// Adapter scripted with a sequence of AdapterResults, one per complete()
/// call. Records every messages list and call options it receives.
final class ScriptedAdapter: ProviderAdapter, @unchecked Sendable {
    let providerName = "mock"
    private let results: [AdapterResult]
    private var cursor = 0
    private(set) var calls: [(messages: [ChatMessage], options: AdapterCallOptions?)] = []
    private let lock = NSLock()

    init(results: [AdapterResult]) {
        self.results = results
    }

    func complete(messages: [ChatMessage], config: PriestConfig, outputSpec: OutputSpec, options: AdapterCallOptions? = nil) async throws -> AdapterResult {
        lock.lock()
        defer { lock.unlock() }
        calls.append((messages, options))
        let result = results[min(cursor, results.count - 1)]
        cursor += 1
        return result
    }
}
