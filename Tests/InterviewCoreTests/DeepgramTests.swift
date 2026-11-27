import XCTest
@testable import InterviewCore

/// Scriptable in-memory socket. Push server messages with `push`, kill it with `fail`.
final class FakeSocket: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var iterator: AsyncThrowingStream<WebSocketMessage, Error>.AsyncIterator
    private let continuation: AsyncThrowingStream<WebSocketMessage, Error>.Continuation
    private var _sentData: [Data] = []
    private var _sentTexts: [String] = []
    private var _closed = false
    let failureStatusCode: Int?
    /// Simulates a server that ends the session when it receives CloseStream.
    let closesOnCloseStream: Bool

    init(failureStatusCode: Int? = nil, closesOnCloseStream: Bool = true) {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: WebSocketMessage.self)
        self.iterator = stream.makeAsyncIterator()
        self.continuation = continuation
        self.failureStatusCode = failureStatusCode
        self.closesOnCloseStream = closesOnCloseStream
    }

    var sentData: [Data] { lock.withLock { _sentData } }
    var sentTexts: [String] { lock.withLock { _sentTexts } }
    var isClosed: Bool { lock.withLock { _closed } }

    func push(_ json: String) { continuation.yield(.text(json)) }
    func fail(_ error: Error = URLError(.networkConnectionLost)) { continuation.finish(throwing: error) }

    func send(_ data: Data) async throws { lock.withLock { _sentData.append(data) } }

    func send(_ text: String) async throws {
        lock.withLock { _sentTexts.append(text) }
        if closesOnCloseStream && text.contains("CloseStream") { continuation.finish() }
    }

    func receive() async throws -> WebSocketMessage {
        guard let message = try await iterator.next() else { throw URLError(.networkConnectionLost) }
        return message
    }

    func close() {
        lock.withLock { _closed = true }
        continuation.finish()
    }
}

final class FakeConnector: WebSocketConnector, @unchecked Sendable {
    enum Step { case socket(FakeSocket), fail(Error) }
    private let lock = NSLock()
    private var steps: [Step]
    private(set) var requests: [URLRequest] = []

    init(_ steps: [Step]) { self.steps = steps }

    var connectCount: Int { lock.withLock { requests.count } }

    func connect(_ request: URLRequest) async throws -> WebSocketConnection {
        let step: Step? = lock.withLock {
            requests.append(request)
            return steps.isEmpty ? nil : steps.removeFirst()
        }
        switch step {
        case .socket(let s): return s
        case .fail(let e): throw e
        case nil: throw URLError(.cannotConnectToHost)
        }
    }
}

private func results(_ text: String, final: Bool = true, start: Double = 0, duration: Double = 1) -> String {
    """
    {"type":"Results","channel_index":[0,1],"duration":\(duration),"start":\(start),"is_final":\(final),"speech_final":\(final),\
    "channel":{"alternatives":[{"transcript":"\(text)","confidence":0.99,"words":[]}]}}
    """
}

private func audio(_ count: Int) -> AsyncStream<PCMChunk> {
    AsyncStream { c in
        for i in 0..<count { c.yield(PCMChunk(data: Data(repeating: UInt8(i), count: 320))) }
        c.finish()
    }
}

private func fastConfig(retries: [TimeInterval] = [0, 0, 0], keepAlive: TimeInterval = 5, grace: TimeInterval = 0.05) -> DeepgramConfiguration {
    DeepgramConfiguration(apiKey: "dg-key", retryDelays: retries, keepAliveInterval: keepAlive, closeGrace: grace)
}

final class DeepgramMessageTests: XCTestCase {
    func testParsesFinalResult() {
        let s = DeepgramMessage.segment(from: results("  hello there ", start: 2, duration: 1.5), speaker: .interviewer, offset: 0)
        XCTAssertEqual(s, TranscriptSegment(speaker: .interviewer, text: "hello there", isFinal: true, start: 2, end: 3.5))
    }

    func testInterimIsNotFinalAndOffsetApplies() {
        let s = DeepgramMessage.segment(from: results("hel", final: false, start: 1, duration: 0.5), speaker: .me, offset: 10)
        XCTAssertEqual(s?.isFinal, false)
        XCTAssertEqual(s?.start, 11)
        XCTAssertEqual(s?.end, 11.5)
        XCTAssertEqual(s?.speaker, .me)
    }

    func testIgnoresEmptyMetadataAndGarbage() {
        XCTAssertNil(DeepgramMessage.segment(from: results("   "), speaker: .me, offset: 0))
        XCTAssertNil(DeepgramMessage.segment(from: #"{"type":"Metadata","request_id":"x"}"#, speaker: .me, offset: 0))
        XCTAssertNil(DeepgramMessage.segment(from: #"{"type":"UtteranceEnd","last_word_end":1.0}"#, speaker: .me, offset: 0))
        XCTAssertNil(DeepgramMessage.segment(from: "nope", speaker: .me, offset: 0))
    }

    func testRequestURLAndAuth() throws {
        let request = DeepgramConfiguration(apiKey: "abc", language: "ru").makeRequest()
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "api.deepgram.com")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ n: String) -> String? { query.first { $0.name == n }?.value }
        XCTAssertEqual(value("encoding"), "linear16")
        XCTAssertEqual(value("sample_rate"), "16000")
        XCTAssertEqual(value("channels"), "1")
        XCTAssertEqual(value("language"), "ru")
        XCTAssertEqual(value("interim_results"), "true")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token abc")
    }
}

final class DeepgramTranscriberTests: XCTestCase {
    private func collect(_ stream: AsyncThrowingStream<TranscriptSegment, Error>) async throws -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for try await s in stream { out.append(s) }
        return out
    }

    func testStreamsSegmentsForwardsAudioAndClosesCleanly() async throws {
        let socket = FakeSocket()
        socket.push(results("first", start: 0, duration: 1))
        socket.push(#"{"type":"Metadata"}"#)
        socket.push(results("second", start: 1, duration: 1))
        let connector = FakeConnector([.socket(socket)])
        let t = DeepgramTranscriber(configuration: fastConfig(), connector: connector)

        let segments = try await collect(t.transcribe(audio: audio(3), speaker: .interviewer))

        XCTAssertEqual(segments.map(\.text), ["first", "second"])
        XCTAssertTrue(segments.allSatisfy { $0.speaker == .interviewer })
        XCTAssertEqual(socket.sentData.count, 3, "every audio chunk must reach the socket")
        XCTAssertTrue(socket.sentTexts.contains { $0.contains("CloseStream") })
        XCTAssertEqual(connector.connectCount, 1)
        XCTAssertEqual(connector.requests.first?.value(forHTTPHeaderField: "Authorization"), "Token dg-key")
    }

    func testClosesSocketAfterGraceWhenServerNeverCloses() async throws {
        let socket = FakeSocket(closesOnCloseStream: false)
        socket.push(results("only"))
        let t = DeepgramTranscriber(configuration: fastConfig(grace: 0.05), connector: FakeConnector([.socket(socket)]))
        let segments = try await collect(t.transcribe(audio: audio(1), speaker: .me))
        XCTAssertEqual(segments.map(\.text), ["only"])
        XCTAssertTrue(socket.isClosed)
    }

    func testRetriesInitialConnectFailure() async throws {
        let socket = FakeSocket()
        socket.push(results("ok"))
        let connector = FakeConnector([.fail(URLError(.cannotConnectToHost)), .socket(socket)])
        let t = DeepgramTranscriber(configuration: fastConfig(), connector: connector)
        let segments = try await collect(t.transcribe(audio: audio(1), speaker: .me))
        XCTAssertEqual(segments.map(\.text), ["ok"])
        XCTAssertEqual(connector.connectCount, 2)
    }

    func testReconnectsAfterMidStreamDropAndKeepsTimestampsMonotonic() async throws {
        let first = FakeSocket()
        first.push(results("before", start: 0, duration: 2))
        let second = FakeSocket()
        second.push(results("after", start: 0, duration: 1))   // server restarts its clock at 0
        let connector = FakeConnector([.socket(first), .socket(second)])
        let t = DeepgramTranscriber(configuration: fastConfig(), connector: connector)

        // Keep audio open until the reconnect has happened.
        let (audioStream, audioC) = AsyncStream.makeStream(of: PCMChunk.self)
        let stream = t.transcribe(audio: audioStream, speaker: .interviewer)
        let collector = Task { try await self.collect(stream) }

        try await Task.sleep(nanoseconds: 100_000_000)
        first.fail()
        try await Task.sleep(nanoseconds: 150_000_000)
        audioC.finish()

        let segments = try await collector.value
        XCTAssertEqual(segments.map(\.text), ["before", "after"])
        XCTAssertGreaterThanOrEqual(segments[1].start, segments[0].end, "clock must continue after reconnect")
        XCTAssertEqual(connector.connectCount, 2)
    }

    func testRejectedKeyIsFatalAndNotRetried() async {
        let socket = FakeSocket(failureStatusCode: 401)
        socket.fail()
        let connector = FakeConnector([.socket(socket), .socket(FakeSocket())])
        let t = DeepgramTranscriber(configuration: fastConfig(), connector: connector)
        let (audioStream, _) = AsyncStream.makeStream(of: PCMChunk.self)
        do {
            _ = try await collect(t.transcribe(audio: audioStream, speaker: .me))
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unauthorized)
            XCTAssertEqual(connector.connectCount, 1)
        }
    }

    func testGivesUpAfterRetryBudget() async {
        let connector = FakeConnector([])   // every connect fails
        let t = DeepgramTranscriber(configuration: fastConfig(retries: [0, 0]), connector: connector)
        let (audioStream, _) = AsyncStream.makeStream(of: PCMChunk.self)
        do {
            _ = try await collect(t.transcribe(audio: audioStream, speaker: .me))
            XCTFail("expected failure")
        } catch {
            guard case .connectionFailed = error as? ProviderError else { return XCTFail("got \(error)") }
            XCTAssertEqual(connector.connectCount, 3, "1 initial attempt + 2 retries")
        }
    }

    func testSendsKeepAlivesWhileIdle() async throws {
        let socket = FakeSocket()
        let t = DeepgramTranscriber(configuration: fastConfig(keepAlive: 0.05), connector: FakeConnector([.socket(socket)]))
        let (audioStream, audioC) = AsyncStream.makeStream(of: PCMChunk.self)
        let collector = Task { try await self.collect(t.transcribe(audio: audioStream, speaker: .me)) }

        try await Task.sleep(nanoseconds: 300_000_000)
        audioC.finish()
        _ = try await collector.value

        let keepAlives = socket.sentTexts.filter { $0.contains("KeepAlive") }.count
        XCTAssertGreaterThanOrEqual(keepAlives, 2)
    }

    func testCancellingTheConsumerClosesTheSocket() async throws {
        let socket = FakeSocket()
        let t = DeepgramTranscriber(configuration: fastConfig(), connector: FakeConnector([.socket(socket)]))
        let (audioStream, _) = AsyncStream.makeStream(of: PCMChunk.self)
        let consumer = Task { try await self.collect(t.transcribe(audio: audioStream, speaker: .me)) }

        try await Task.sleep(nanoseconds: 100_000_000)
        consumer.cancel()
        _ = try? await consumer.value
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(socket.isClosed)
    }
}
