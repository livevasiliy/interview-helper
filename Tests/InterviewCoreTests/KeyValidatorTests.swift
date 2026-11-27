import XCTest
@testable import InterviewCore

final class KeyValidatorTests: XCTestCase {
    func testNormalizeStripsWhitespaceQuotesBearerAndEnvPrefix() {
        XCTAssertEqual(KeyValidator.normalize("  AIzaSy123456789 \n"), "AIzaSy123456789")
        XCTAssertEqual(KeyValidator.normalize("\"gsk_abcdefgh\""), "gsk_abcdefgh")
        XCTAssertEqual(KeyValidator.normalize("Bearer sk-abcdefgh"), "sk-abcdefgh")
        XCTAssertEqual(KeyValidator.normalize("GEMINI_API_KEY=AIzaSy123456789"), "AIzaSy123456789")
        XCTAssertEqual(KeyValidator.normalize("GROQ_API_KEY='gsk_abcdefgh'"), "gsk_abcdefgh")
        XCTAssertEqual(KeyValidator.normalize("abc=def"), "abc=def", "lower-case text before = is not an env assignment")
    }

    func testFormatProblems() {
        XCTAssertNotNil(KeyValidator.formatProblem("", for: .geminiAPIKey))
        XCTAssertNotNil(KeyValidator.formatProblem("two words here", for: .geminiAPIKey))
        XCTAssertNotNil(KeyValidator.formatProblem("short", for: .geminiAPIKey))
        XCTAssertNotNil(KeyValidator.formatProblem("ключ-ключ-ключ", for: .geminiAPIKey))
        XCTAssertNil(KeyValidator.formatProblem("AIzaSy-abcdefghijk", for: .geminiAPIKey))
    }

    func testWrongServiceIsOnlyAWarning() {
        XCTAssertNil(KeyValidator.formatWarning("AIzaSy-abcdefghijk", for: .geminiAPIKey))
        XCTAssertNotNil(KeyValidator.formatWarning("gsk_abcdefghijk", for: .geminiAPIKey))
        XCTAssertNil(KeyValidator.formatWarning("gsk_abcdefghijk", for: .groqAPIKey))
        XCTAssertNotNil(KeyValidator.formatWarning("sk-ant-abcdefgh", for: .openAIAPIKey))
        XCTAssertNil(KeyValidator.formatWarning("sk-abcdefgh", for: .openAIAPIKey))
        XCTAssertNotNil(KeyValidator.formatWarning("sk-abcdefgh", for: .deepgramAPIKey))
        XCTAssertNil(KeyValidator.formatWarning("0123456789abcdef0123456789abcdef01234567", for: .deepgramAPIKey))
    }

    func testEachProviderGetsItsOwnAuthenticatedRequest() {
        let v = KeyValidator()
        let gemini = v.request(for: .geminiAPIKey, key: "K")
        XCTAssertEqual(gemini.url?.host, "generativelanguage.googleapis.com")
        XCTAssertEqual(gemini.value(forHTTPHeaderField: "x-goog-api-key"), "K")
        XCTAssertNil(gemini.url?.query?.contains("key=K") == true ? "leak" : nil, "the key travels in a header, not the URL")
        XCTAssertEqual(v.request(for: .groqAPIKey, key: "K").value(forHTTPHeaderField: "Authorization"), "Bearer K")
        XCTAssertEqual(v.request(for: .anthropicAPIKey, key: "K").value(forHTTPHeaderField: "x-api-key"), "K")
        XCTAssertEqual(v.request(for: .deepgramAPIKey, key: "K").value(forHTTPHeaderField: "Authorization"), "Token K")
        XCTAssertEqual(v.request(for: .openRouterAPIKey, key: "K").url?.path, "/api/v1/auth/key")
        for slot in SecretKey.allCases {
            XCTAssertEqual(v.request(for: slot, key: "K").url?.scheme, "https")
            XCTAssertEqual(v.request(for: slot, key: "K").httpMethod, "GET")
        }
    }

    private func check(status: Int, slot: SecretKey = .groqAPIKey) async -> KeyCheck {
        StubURLProtocol.reset(status: status, chunks: ["{}"])
        return await KeyValidator(session: StubURLProtocol.session()).check("gsk_abcdefgh", for: slot)
    }

    func testProviderAnswersMapToOutcomes() async {
        let ok = await check(status: 200)
        XCTAssertEqual(ok, .valid)
        for status in [401, 403] {
            let rejected = await check(status: status)
            if case .rejected = rejected {} else { XCTFail("\(status) should reject, got \(rejected)") }
        }
        // Gemini answers a bad key with 400.
        let gemini = await check(status: 400, slot: .geminiAPIKey)
        if case .rejected = gemini {} else { XCTFail("Gemini 400 should reject") }
        let other400 = await check(status: 400)
        if case .unverified = other400 {} else { XCTFail("400 elsewhere is not proof the key is bad") }
        for status in [429, 500, 503] {
            let result = await check(status: status)
            if case .unverified = result {} else { XCTFail("\(status) should be unverified, got \(result)") }
        }
    }

    func testNetworkFailureIsUnverifiedNotRejected() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingURLProtocol.self]
        let result = await KeyValidator(session: URLSession(configuration: config)).check("gsk_abcdefgh", for: .groqAPIKey)
        if case .unverified = result {} else { XCTFail("offline must not discard a possibly good key") }
    }
}

final class FailingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
