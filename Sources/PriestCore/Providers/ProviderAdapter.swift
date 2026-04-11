/// Protocol for provider adapters.
///
/// Adapters are thin translators: messages in, AdapterResult out.
/// They do not inspect profile content, call back into the engine,
/// or perform any business logic beyond sending the request and
/// normalizing the response.
public protocol ProviderAdapter: Sendable {
    var providerName: String { get }

    func complete(
        messages: [[String: String]],
        config: PriestConfig,
        outputSpec: OutputSpec
    ) async throws -> AdapterResult

    func stream(
        messages: [[String: String]],
        config: PriestConfig,
        outputSpec: OutputSpec
    ) -> AsyncThrowingStream<String, Error>
}

// MARK: - Default stream implementation

public extension ProviderAdapter {
    /// Default stream: calls complete() and yields the full text as a single chunk.
    /// Adapters with native streaming support should override this.
    func stream(
        messages: [[String: String]],
        config: PriestConfig,
        outputSpec: OutputSpec
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await complete(messages: messages, config: config, outputSpec: outputSpec)
                    if let text = result.text, !text.isEmpty {
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
