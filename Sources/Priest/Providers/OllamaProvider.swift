import Foundation

/// Provider adapter for Ollama's /api/chat endpoint.
///
/// Supports native streaming via NDJSON (URLSession.bytes).
/// See `behavior/providers.md` for the full translation specification.
public final class OllamaProvider: ProviderAdapter {
    public let providerName = "ollama"
    private let baseURL: URL

    public init(baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.baseURL = baseURL
    }

    // MARK: - complete

    public func complete(
        messages: [[String: String]],
        config: PriestConfig,
        outputSpec: OutputSpec
    ) async throws -> AdapterResult {
        let payload = buildPayload(messages: messages, config: config, outputSpec: outputSpec, stream: false)
        let data = try await post(path: "/api/chat", payload: payload, timeout: config.timeoutSeconds)
        let json = try parseJSON(data)
        let text = (json["message"] as? [String: Any]).flatMap { $0["content"] as? String }
        let doneReason = json["done_reason"] as? String
        return AdapterResult(
            text: text,
            finishReason: mapFinishReason(doneReason),
            inputTokens: json["prompt_eval_count"] as? Int,
            outputTokens: json["eval_count"] as? Int
        )
    }

    // MARK: - stream

    public func stream(
        messages: [[String: String]],
        config: PriestConfig,
        outputSpec: OutputSpec
    ) -> AsyncThrowingStream<String, Error> {
        let payload = buildPayload(messages: messages, config: config, outputSpec: outputSpec, stream: true)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = try self.buildRequest(path: "/api/chat", payload: payload, timeout: config.timeoutSeconds)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw PriestError.providerError(self.providerName, message: "No HTTP response")
                    }
                    try self.checkStatus(httpResponse, provider: self.providerName)
                    for try await line in bytes.lines {
                        guard !line.isEmpty else { continue }
                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let content = (obj["message"] as? [String: Any])?["content"] as? String, !content.isEmpty {
                            continuation.yield(content)
                        }
                        if obj["done"] as? Bool == true { break }
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

    private func buildPayload(messages: [[String: String]], config: PriestConfig, outputSpec: OutputSpec, stream: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "stream": stream,
        ]
        if let n = config.maxOutputTokens {
            payload["options"] = ["num_predict": n]
        }
        if outputSpec.providerFormat == .json {
            payload["format"] = "json"
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
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
        case "stop", "load": return "stop"
        case "length":       return "length"
        default:             return "unknown"
        }
    }
}
