import Foundation

/// Provider adapter for Anthropic's /v1/messages endpoint.
///
/// Anthropic's API shape differs from OpenAI: system content is a top-level
/// field, not a message in the array, and auth uses x-api-key header.
///
/// Supports native SSE streaming via URLSession.bytes.
/// See `behavior/providers.md` for the full translation specification.
public final class AnthropicProvider: ProviderAdapter {
    public let providerName = "anthropic"
    private let apiKey: String
    private let baseURL: URL

    private static let apiVersion = "2023-06-01"
    private static let defaultMaxTokens = 8096

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    // MARK: - complete

    public func complete(
        messages: [[String: String]],
        config: PriestConfig,
        outputSpec: OutputSpec
    ) async throws -> AdapterResult {
        let payload = buildPayload(messages: messages, config: config)
        let data = try await post(path: "/v1/messages", payload: payload, timeout: config.timeoutSeconds)
        let json = try parseJSON(data)
        let contentBlocks = json["content"] as? [[String: Any]] ?? []
        let text = contentBlocks.first(where: { $0["type"] as? String == "text" }).flatMap { $0["text"] as? String }
        let usage = json["usage"] as? [String: Any]
        return AdapterResult(
            text: text,
            finishReason: mapFinishReason(json["stop_reason"] as? String),
            inputTokens: usage?["input_tokens"] as? Int,
            outputTokens: usage?["output_tokens"] as? Int
        )
    }

    // MARK: - stream

    public func stream(
        messages: [[String: String]],
        config: PriestConfig,
        outputSpec: OutputSpec
    ) -> AsyncThrowingStream<String, Error> {
        var payload = buildPayload(messages: messages, config: config)
        payload["stream"] = true
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = try self.buildRequest(path: "/v1/messages", payload: payload, timeout: config.timeoutSeconds)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw PriestError.providerError(self.providerName, message: "No HTTP response")
                    }
                    try self.checkStatus(httpResponse, provider: self.providerName)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let raw = String(line.dropFirst(6))
                        guard let data = raw.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if obj["type"] as? String == "content_block_delta",
                           let delta = obj["delta"] as? [String: Any],
                           let text = delta["text"] as? String, !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch let e as PriestError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: PriestError.providerError(self.providerName, message: error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Helpers

    private func buildPayload(messages: [[String: String]], config: PriestConfig) -> [String: Any] {
        // Extract system messages — Anthropic requires them as a top-level field
        let systemParts = messages.filter { $0["role"] == "system" }.compactMap { $0["content"] }
        let turns = messages.filter { $0["role"] != "system" }

        var payload: [String: Any] = [
            "model": config.model,
            "messages": turns,
            "max_tokens": config.maxOutputTokens ?? AnthropicProvider.defaultMaxTokens,
        ]
        if !systemParts.isEmpty {
            payload["system"] = systemParts.joined(separator: "\n\n")
        }
        for (k, v) in config.providerOptions {
            payload[k] = v.toFoundation()
        }
        return payload
    }

    private func buildRequest(path: String, payload: [String: Any], timeout: Double) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(AnthropicProvider.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return req
    }

    private func post(path: String, payload: [String: Any], timeout: Double) async throws -> Data {
        let request = try buildRequest(path: path, payload: payload, timeout: timeout)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PriestError.providerError(providerName, message: "No HTTP response")
            }
            try checkStatus(httpResponse, provider: providerName)
            return data
        } catch let e as PriestError { throw e }
        catch let urlError as URLError where urlError.code == .timedOut {
            throw PriestError.providerTimeout(providerName, timeout: timeout)
        } catch {
            throw PriestError.providerError(providerName, message: error.localizedDescription)
        }
    }

    private func checkStatus(_ response: HTTPURLResponse, provider: String) throws {
        if response.statusCode == 429 { throw PriestError.providerRateLimited(provider) }
        guard (200..<300).contains(response.statusCode) else {
            throw PriestError.providerError(provider, message: "HTTP \(response.statusCode)")
        }
    }

    private func parseJSON(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PriestError.providerError(providerName, message: "Invalid JSON response")
        }
        return obj
    }

    private func mapFinishReason(_ reason: String?) -> String? {
        guard let reason else { return nil }
        switch reason {
        case "end_turn", "stop_sequence": return "stop"
        case "max_tokens":                return "length"
        default:                          return "unknown"
        }
    }
}
