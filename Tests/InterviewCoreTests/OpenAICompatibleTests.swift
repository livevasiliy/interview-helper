import XCTest
@testable import InterviewCore

final class OpenAIParserTests: XCTestCase {
    func testContentDeltaIsReturned() throws {
        var p = OpenAIStreamParser()
        XCTAssertEqual(try p.feed(line: #"data: {"choices":[{"index":0,"delta":{"content":"Hi"}}]}"#), "Hi")
    }

    func testIgnoresRoleOnlyEmptyAndNonDataLines() throws {
        var p = OpenAIStreamParser()
        XCTAssertNil(try p.feed(line: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#))
        XCTAssertNil(try p.feed(line: #"data: {"choices":[{"delta":{"content":""}}]}"#))
        XCTAssertNil(try p.feed(line: #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#))
        XCTAssertNil(try p.feed(line: #"data: {"choices":[],"usage":{"total_tokens":5}}"#))
        XCTAssertNil(try p.feed(line: ": keep-alive"))
        XCTAssertNil(try p.feed(line: ""))
        XCTAssertNil(try p.feed(line: "data: not json"))
        XCTAssertFalse(p.isDone)
    }

    func testDoneMarker() throws {
        var p = OpenAIStreamParser()
        XCTAssertNil(try p.feed(line: "data: [DONE]"))
        XCTAssertTrue(p.isDone)
    }

    func testErrorChunkThrows() {
        var p = OpenAIStreamParser()
        XCTAssertThrowsError(try p.feed(line: #"data: {"error":{"message":"quota exceeded","type":"rate_limit"}}"#)) {
            XCTAssertEqual($0 as? ProviderError, .api("quota exceeded"))
        }
    }
}

final class OpenAICompatibleEngineTests: XCTestCase {
    private let prompt = AnswerPrompt(system: "Be brief.", messages: [PromptMessage(role: .user, content: "Why?")])
    private let base = URL(string: "https://example.test/v1")!

    private func chunk(_ text: String) -> String {
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\(text)\"}}]}\n\n"
    }

    private func collect(_ engine: OpenAICompatibleAnswerEngine) async throws -> String {
        var out = ""
        for try await token in engine.answer(for: prompt) { out += token }
        return out
    }

    func testRequestShapeWithKey() throws {
        let engine = OpenAICompatibleAnswerEngine(baseURL: base, apiKey: "secret", model: "m-1", maxTokens: 321)
        let request = try engine.makeRequest(for: prompt)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer secret")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "m-1")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, 321)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "system", "content": "Be brief."], ["role": "user", "content": "Why?"]],
                       "the system prompt goes first, as a message")
    }

    func testNoAuthorizationHeaderWithoutKey() throws {
        let request = try OpenAICompatibleAnswerEngine(baseURL: base, apiKey: "", model: "m").makeRequest(for: prompt)
        XCTAssertNil(request.value(forHTTPHeaderField: "authorization"), "Ollama needs no key")
    }

    func testStreamsAcrossChunkBoundaries() async throws {
        let full = chunk("Hello") + chunk(", world") + "data: [DONE]\n\n"
        let cut = full.index(full.startIndex, offsetBy: 41)
        StubURLProtocol.reset(chunks: [String(full[..<cut]), String(full[cut...])])
        let engine = OpenAICompatibleAnswerEngine(baseURL: base, apiKey: "k", model: "m", session: StubURLProtocol.session())
        let text = try await collect(engine)
        XCTAssertEqual(text, "Hello, world")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "authorization"), "Bearer k")
    }

    func testUnauthorizedAndProviderMessages() async {
        StubURLProtocol.reset(status: 401, chunks: [#"{"error":{"message":"bad key"}}"#])
        let engine = OpenAICompatibleAnswerEngine(baseURL: base, apiKey: "bad", model: "m", session: StubURLProtocol.session())
        do { _ = try await collect(engine); XCTFail("expected error") } catch {
            XCTAssertEqual(error as? ProviderError, .unauthorized)
        }

        StubURLProtocol.reset(status: 429, chunks: [#"[{"error":{"message":"Resource exhausted"}}]"#])   // Google's array form
        let limited = OpenAICompatibleAnswerEngine(baseURL: base, apiKey: "k", model: "m", session: StubURLProtocol.session())
        do { _ = try await collect(limited); XCTFail("expected error") } catch {
            XCTAssertEqual(error as? ProviderError, .http(status: 429, message: "Resource exhausted"))
        }

        StubURLProtocol.reset(status: 404, chunks: [#"{"error":{"message":"model 'llama3.1:8b' not found"}}"#])
        let missing = OpenAICompatibleAnswerEngine(baseURL: base, apiKey: "", model: "llama3.1:8b", session: StubURLProtocol.session())
        do { _ = try await collect(missing); XCTFail("expected error") } catch {
            XCTAssertEqual(error as? ProviderError, .http(status: 404, message: "model 'llama3.1:8b' not found"))
        }
    }

    func testMidStreamErrorSurfacesAfterEarlierTokens() async {
        StubURLProtocol.reset(chunks: [chunk("Part"), "data: {\"error\":{\"message\":\"overloaded\"}}\n\n"])
        let engine = OpenAICompatibleAnswerEngine(baseURL: base, apiKey: "k", model: "m", session: StubURLProtocol.session())
        var got = ""
        do {
            for try await t in engine.answer(for: prompt) { got += t }
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(got, "Part")
            XCTAssertEqual(error as? ProviderError, .api("overloaded"))
        }
    }
}
