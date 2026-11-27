import XCTest
@testable import InterviewCore

/// Records how often it was called, then behaves like `FakeAnswerEngine`.
final class CountingEngine: AnswerEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    let tokens: [String]
    let failure: (any Error)?

    init(tokens: [String] = [], failure: (any Error)? = nil) {
        self.tokens = tokens
        self.failure = failure
    }

    var calls: Int { lock.withLock { _calls } }

    func answer(for prompt: AnswerPrompt) -> AsyncThrowingStream<String, Error> {
        lock.withLock { _calls += 1 }
        return AsyncThrowingStream { continuation in
            for t in tokens { continuation.yield(t) }
            continuation.finish(throwing: failure)
        }
    }
}

final class FallbackAnswerEngineTests: XCTestCase {
    private let prompt = AnswerPrompt(system: "s", messages: [PromptMessage(role: .user, content: "q")])
    private let busy = ProviderError.http(status: 503, message: "This model is currently experiencing high demand")

    private func run(_ engine: FallbackAnswerEngine) async throws -> String {
        var out = ""
        for try await t in engine.answer(for: prompt) { out += t }
        return out
    }

    func testBusyPrimaryIsRetriedOnceThenABackupAnswers() async throws {
        let primary = CountingEngine(failure: busy)
        let backup = CountingEngine(tokens: ["from ", "backup"])
        let engine = FallbackAnswerEngine(engines: [primary, backup], delay: 0)
        let text = try await run(engine)
        XCTAssertEqual(text, "from backup")
        XCTAssertEqual(primary.calls, 2, "the primary gets one retry")
        XCTAssertEqual(backup.calls, 1)
    }

    func testHealthyPrimaryNeverTouchesTheBackup() async throws {
        let primary = CountingEngine(tokens: ["ok"])
        let backup = CountingEngine(tokens: ["backup"])
        let text = try await run(FallbackAnswerEngine(engines: [primary, backup], delay: 0))
        XCTAssertEqual(text, "ok")
        XCTAssertEqual(primary.calls, 1)
        XCTAssertEqual(backup.calls, 0)
    }

    func testRejectedKeyIsNotRetried() async {
        let primary = CountingEngine(failure: ProviderError.unauthorized)
        let backup = CountingEngine(tokens: ["x"])
        do {
            _ = try await run(FallbackAnswerEngine(engines: [primary, backup], delay: 0))
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unauthorized)
            XCTAssertEqual(primary.calls, 1)
            XCTAssertEqual(backup.calls, 0)
        }
    }

    func testUnknownModelFallsBackToTheNextOne() async throws {
        let primary = CountingEngine(failure: ProviderError.http(status: 404, message: "model not found"))
        let backup = CountingEngine(tokens: ["fine"])
        let text = try await run(FallbackAnswerEngine(engines: [primary, backup], delay: 0))
        XCTAssertEqual(text, "fine")
    }

    func testRateLimitAndNetworkErrorsFallBack() async throws {
        for error in [ProviderError.http(status: 429, message: "quota"), ProviderError.connectionFailed("offline"), URLError(.timedOut)] as [Error] {
            let backup = CountingEngine(tokens: ["ok"])
            let text = try await run(FallbackAnswerEngine(engines: [CountingEngine(failure: error), backup], delay: 0))
            XCTAssertEqual(text, "ok", "\(error)")
        }
    }

    func testBadRequestIsReportedNotRetried() async {
        let primary = CountingEngine(failure: ProviderError.http(status: 400, message: "bad request"))
        let backup = CountingEngine(tokens: ["x"])
        do {
            _ = try await run(FallbackAnswerEngine(engines: [primary, backup], delay: 0))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .http(status: 400, message: "bad request"))
            XCTAssertEqual(backup.calls, 0)
        }
    }

    func testFailureAfterTextWasShownIsNotRetried() async {
        let primary = CountingEngine(tokens: ["Part"], failure: ProviderError.api("overloaded"))
        let backup = CountingEngine(tokens: ["other"])
        let engine = FallbackAnswerEngine(engines: [primary, backup], delay: 0)
        var got = ""
        do {
            for try await t in engine.answer(for: prompt) { got += t }
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(got, "Part")
            XCTAssertEqual(error as? ProviderError, .api("overloaded"))
            XCTAssertEqual(primary.calls, 1, "no retry once text was produced")
            XCTAssertEqual(backup.calls, 0)
        }
    }

    func testAllEnginesFailingReportsWhyEachModelFailed() async {
        let a = CountingEngine(failure: busy)
        let b = CountingEngine(failure: ProviderError.http(status: 404, message: "no longer available to new users"))
        let engine = FallbackAnswerEngine(engines: [a, b], names: ["model-a", "model-b"], delay: 0)
        do {
            _ = try await run(engine)
            XCTFail("expected error")
        } catch {
            guard case .allModelsFailed(let details)? = error as? ProviderError else { return XCTFail("got \(error)") }
            let lines = details.split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.count, 2, "one line per model, the retried primary is listed once")
            XCTAssertTrue(lines[0].hasPrefix("model-a → HTTP 503"), lines[0])
            XCTAssertTrue(lines[1].hasPrefix("model-b → HTTP 404"), lines[1])
            XCTAssertEqual(a.calls, 2)
            XCTAssertEqual(b.calls, 1)
        }
    }

    func testReportDescriptionIsReadable() {
        let error = FallbackAnswerEngine.report([("m1", ProviderError.http(status: 503, message: "busy")), ("m2", URLError(.timedOut))])
        XCTAssertTrue(error.errorDescription?.hasPrefix("No model could answer.") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("m1 → HTTP 503: busy") ?? false)
        XCTAssertEqual(FallbackAnswerEngine.report([]), .connectionFailed("No answer engine is available"))
    }

    func testCancellingTheConsumerStopsFurtherAttempts() async {
        let primary = CountingEngine(failure: busy)
        let backup = CountingEngine(tokens: ["x"])
        let engine = FallbackAnswerEngine(engines: [primary, backup], delay: 5)   // long pause between attempts
        let task = Task { try await self.run(engine) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        _ = try? await task.value
        XCTAssertEqual(primary.calls, 1)
        XCTAssertEqual(backup.calls, 0)
    }
}
