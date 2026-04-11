import Foundation
@testable import PriestCore

/// Fake provider adapter for unit tests — no network calls.
final class MockAdapter: ProviderAdapter {
    let providerName = "mock"
    let text: String
    let finishReason: String

    init(text: String = "hello", finishReason: String = "stop") {
        self.text = text
        self.finishReason = finishReason
    }

    func complete(messages: [[String: String]], config: PriestConfig, outputSpec: OutputSpec) async throws -> AdapterResult {
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

    func complete(messages: [[String: String]], config: PriestConfig, outputSpec: OutputSpec) async throws -> AdapterResult {
        AdapterResult(text: text, finishReason: "stop", inputTokens: 10, outputTokens: 5)
    }

    func stream(messages: [[String: String]], config: PriestConfig, outputSpec: OutputSpec) -> AsyncThrowingStream<String, Error> {
        let words = text.split(separator: " ").map(String.init)
        return AsyncThrowingStream { continuation in
            Task {
                for word in words { continuation.yield(word) }
                continuation.finish()
            }
        }
    }
}
