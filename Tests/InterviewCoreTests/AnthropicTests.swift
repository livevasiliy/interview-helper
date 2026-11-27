import XCTest
@testable import InterviewCore

/// Serves canned responses to URLSession without touching the network.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var chunks: [Data] = []
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    static func reset(status: Int = 200, chunks: [String] = []) {
        self.status = status
        self.chunks = chunks.map { Data($0.utf8) }
        lastRequest = nil
        lastBody = nil
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            Self.lastBody = data
        } else {
            Self.lastBody = request.httpBody
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in Self.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AnthropicParserTests: XCTestCase {
    func testTextDeltaIsReturned() throws {
        var p = AnthropicStreamParser()
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#
        XCTAssertEqual(try p.feed(line: line), "Hi")
    }

    func testIgnoresEventLinesPingsAndOtherDeltas() throws {
        var p = AnthropicStreamParser()
        XCTAssertNil(try p.feed(line: "event: content_block_delta"))
        XCTAssertNil(try p.feed(line: ""))
        XCTAssertNil(try p.feed(line: #"data: {"type":"ping"}"#))
        XCTAssertNil(try p.feed(line: #"data: {"type":"message_start","message":{"id":"x"}}"#))
        XCTAssertNil(try p.feed(line: #"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}}"#))
        XCTAssertNil(try p.feed(line: "data: not json"))
        XCTAssertFalse(p.isDone)
    }

    func testMessageStopAndDoneMarkFinished() throws {
        var a = AnthropicStreamParser()
        _ = try a.feed(line: #"data: {"type":"message_stop"}"#)
        XCTAssertTrue(a.isDone)
        var b = AnthropicStreamParser()
        _ = try b.feed(line: "data: [DONE]")
        XCTAssertTrue(b.isDone)
    }

    func testErrorEventThrows() {
        var p = AnthropicStreamParser()
        let line = #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        XCTAssertThrowsError(try p.feed(line: line)) { error in
            XCTAssertEqual(error as? ProviderError, .api("overloaded_error: Overloaded"))
        }
    }
}

final class AnthropicEngineTests: XCTestCase {
    private let prompt = AnswerPrompt(system: "Be brief.", messages: [PromptMessage(role: .user, content: "Why?")])

    private func delta(_ text: String) -> String {
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\(text)\"}}\n\n"
    }

    private func collect(_ engine: AnthropicAnswerEngine) async throws -> String {
        var out = ""
        for try await token in engine.answer(for: prompt) { out += token }
        return out
    }

    func testRequestShape() throws {
        let engine = AnthropicAnswerEngine(apiKey: "sk-test", model: "m-1", maxTokens: 123)
        let request = try engine.makeRequest(for: prompt)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "m-1")
        XCTAssertEqual(body["max_tokens"] as? Int, 123)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["system"] as? String, "Be brief.")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "user", "content": "Why?"]])
    }

    func testStreamsTokensAcrossArbitraryChunkBoundaries() async throws {
        let full = "event: message_start\ndata: {\"type\":\"message_start\"}\n\n"
            + delta("Hello") + "event: ping\ndata: {\"type\":\"ping\"}\n\n" + delta(", world")
            + "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        // Split mid-line so line reassembly is exercised.
        let mid = full.index(full.startIndex, offsetBy: 97)
        StubURLProtocol.reset(chunks: [String(full[..<mid]), String(full[mid...])])

        let engine = AnthropicAnswerEngine(apiKey: "k", session: StubURLProtocol.session())
        let text = try await collect(engine)
        XCTAssertEqual(text, "Hello, world")

        // The request really went out with our key and body.
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "x-api-key"), "k")
        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: body))
    }

    func testUnauthorizedMapsToProviderError() async {
        StubURLProtocol.reset(status: 401, chunks: [#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#])
        let engine = AnthropicAnswerEngine(apiKey: "bad", session: StubURLProtocol.session())
        do {
            _ = try await collect(engine)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unauthorized)
        }
    }

    func testRateLimitCarriesProviderMessage() async {
        StubURLProtocol.reset(status: 429, chunks: [#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#])
        let engine = AnthropicAnswerEngine(apiKey: "k", session: StubURLProtocol.session())
        do {
            _ = try await collect(engine)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .http(status: 429, message: "slow down"))
        }
    }

    func testMidStreamErrorEventSurfacesAfterEarlierTokens() async {
        StubURLProtocol.reset(chunks: [
            delta("Part"),
            "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n",
        ])
        let engine = AnthropicAnswerEngine(apiKey: "k", session: StubURLProtocol.session())
        var got = ""
        do {
            for try await t in engine.answer(for: prompt) { got += t }
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(got, "Part")
            XCTAssertEqual(error as? ProviderError, .api("overloaded_error: Overloaded"))
        }
    }
}
