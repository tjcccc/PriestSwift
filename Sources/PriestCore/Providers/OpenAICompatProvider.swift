import Foundation

/// Provider adapter for any OpenAI-compatible /v1/chat/completions endpoint.
///
/// Covers: OpenAI, Gemini, Bailian, Alibaba Cloud, MiniMax, DeepSeek, Kimi,
/// Groq, OpenRouter, and any custom base_url.
///
/// Uses URLSession natively — no threading workarounds needed on iOS/macOS.
/// See `behavior/providers.md` for the full translation specification.
public final class OpenAICompatProvider: ProviderAdapter {
    public let providerName: String
    private let baseURL: URL
    private let apiKey: String

    public init(name: String, baseURL: URL, apiKey: String = "") {
        self.providerName = name
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    // MARK: - complete

    public func complete(
        messages: [[String: String]],
        config: PriestConfig,
        outputSpec: OutputSpec
    ) async throws -> AdapterResult {
        let payload = buildPayload(messages: messages, config: config, outputSpec: outputSpec)
        let data = try await post(path: "/v1/chat/completions", payload: payload, timeout: config.timeoutSeconds)
        let json = try parseJSON(data)
        let choices = json["choices"] as? [[String: Any]] ?? []
        let message = choices.first.flatMap { $0["message"] as? [String: Any] }
        let text = message?["content"] as? String
        let finishReason = choices.first?["finish_reason"] as? String
        let usage = json["usage"] as? [String: Any]
        return AdapterResult(
            text: text,
            finishReason: mapFinishReason(finishReason),
            inputTokens: usage?["prompt_tokens"] as? Int,
            outputTokens: usage?["completion_tokens"] as? Int
        )
    }

    // MARK: - stream

    public func stream(
        messages: [[String: String]],
        config: PriestConfig,
        outputSpec: OutputSpec
    ) -> AsyncThrowingStream<String, Error> {
        var payload = buildPayload(messages: messages, config: config, outputSpec: outputSpec)
        payload["stream"] = true
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = try self.buildRequest(path: "/v1/chat/completions", payload: payload, timeout: config.timeoutSeconds)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw PriestError.providerError(self.providerName, message: "No HTTP response")
                    }
                    try self.checkStatus(httpResponse, provider: self.providerName)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let raw = String(line.dropFirst(6))
                        if raw == "[DONE]" { break }
                        guard let data = raw.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        let choices = obj["choices"] as? [[String: Any]] ?? []
                        if let delta = choices.first?["delta"] as? [String: Any],
                           let content = delta["content"] as? String, !content.isEmpty {
                            continuation.yield(content)
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

    private func buildPayload(messages: [[String: String]], config: PriestConfig, outputSpec: OutputSpec) -> [String: Any] {
        var payload: [String: Any] = [
            "model": config.model,
            "messages": messages,
        ]
        if let n = config.maxOutputTokens { payload["max_tokens"] = n }
        if outputSpec.providerFormat == .json {
            payload["response_format"] = ["type": "json_object"]
        }
        if !config.providerOptions.isEmpty {
            // extra_body: merged into the request body (same semantics as Python's extra_body)
            for (k, v) in config.providerOptions { payload[k] = v.toFoundation() }
        }
        return payload
    }

    private func buildRequest(path: String, payload: [String: Any], timeout: Double) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
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
        case "stop":   return "stop"
        case "length": return "length"
        default:       return "unknown"
        }
    }
}
