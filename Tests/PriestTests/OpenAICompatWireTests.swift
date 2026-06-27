import XCTest
import Foundation
@testable import Priest

/// Wire-format tests for the OpenAI-compatible request body.
final class OpenAICompatWireTests: XCTestCase {

    private let provider = OpenAICompatProvider(name: "test", baseURL: URL(string: "https://api.test")!)

    func testStreamingRequestsUsageAndNonStreamingOmitsIt() {
        let config = PriestConfig(provider: "test", model: "test-model")

        let streaming = provider.buildPayload(
            messages: [], config: config, outputSpec: OutputSpec(), options: nil, stream: true)
        XCTAssertEqual(streaming["stream"] as? Bool, true)
        let streamOptions = streaming["stream_options"] as? [String: Any]
        XCTAssertEqual(streamOptions?["include_usage"] as? Bool, true)

        let nonStreaming = provider.buildPayload(
            messages: [], config: config, outputSpec: OutputSpec(), options: nil)
        XCTAssertNil(nonStreaming["stream"])
        XCTAssertNil(nonStreaming["stream_options"])
    }

    func testProviderOptionsOverrideStreamOptions() {
        let config = PriestConfig(
            provider: "test", model: "test-model",
            providerOptions: ["stream_options": .object(["include_usage": .bool(false)])])

        let payload = provider.buildPayload(
            messages: [], config: config, outputSpec: OutputSpec(), options: nil, stream: true)
        let streamOptions = payload["stream_options"] as? [String: Any]
        XCTAssertEqual(streamOptions?["include_usage"] as? Bool, false)
    }
}
