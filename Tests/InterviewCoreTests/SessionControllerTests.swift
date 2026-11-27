import XCTest
@testable import InterviewCore

// MARK: - Test doubles

final class SpyAudioSource: AudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _startCount = 0
    private var _stopCount = 0
    let startError: (any Error)?

    init(startError: (any Error)? = nil) { self.startError = startError }

    var startCount: Int { lock.withLock { _startCount } }
    var stopCount: Int { lock.withLock { _stopCount } }

    func start() async throws -> AsyncStream<PCMChunk> {
        lock.withLock { _startCount += 1 }
        if let startError { throw startError }
        return AsyncStream { _ in }   // never yields; transcription is driven by ControlledTranscriber
    }

    func stop() async { lock.withLock { _stopCount += 1 } }
}

/// Transcriber whose output the test drives by hand, per speaker.
final class ControlledTranscriber: Transcriber, @unchecked Sendable {
    private var streams: [Speaker: AsyncThrowingStream<TranscriptSegment, Error>] = [:]
    private var continuations: [Speaker: AsyncThrowingStream<TranscriptSegment, Error>.Continuation] = [:]

    init() {
        for speaker in [Speaker.interviewer, .me] {
            let (s, c) = AsyncThrowingStream.makeStream(of: TranscriptSegment.self)
            streams[speaker] = s
            continuations[speaker] = c
        }
    }

    func transcribe(audio: AsyncStream<PCMChunk>, speaker: Speaker) -> AsyncThrowingStream<TranscriptSegment, Error> {
        streams[speaker]!
    }

    func push(_ speaker: Speaker, _ text: String, start: Double = 0, end: Double = 1, final: Bool = true) {
        continuations[speaker]!.yield(TranscriptSegment(speaker: speaker, text: text, isFinal: final, start: start, end: end))
    }

    func fail(_ speaker: Speaker, _ error: Error) { continuations[speaker]!.finish(throwing: error) }
}

/// Engine that records prompts; optionally emits one token then hangs until cancelled.
final class ScriptedEngine: AnswerEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _prompts: [AnswerPrompt] = []
    private var _cancelled = 0
    let tokens: [String]
    let hangs: Bool
    let failure: (any Error)?

    init(tokens: [String] = ["ok"], hangs: Bool = false, failure: (any Error)? = nil) {
        self.tokens = tokens
        self.hangs = hangs
        self.failure = failure
    }

    var prompts: [AnswerPrompt] { lock.withLock { _prompts } }
    var cancelledCount: Int { lock.withLock { _cancelled } }

    func answer(for prompt: AnswerPrompt) -> AsyncThrowingStream<String, Error> {
        lock.withLock { _prompts.append(prompt) }
        return AsyncThrowingStream { continuation in
            for t in tokens { continuation.yield(t) }
            if hangs {
                continuation.onTermination = { [weak self] reason in
                    if case .cancelled = reason { self?.lock.withLock { self?._cancelled += 1 } }
                }
            } else {
                continuation.finish(throwing: failure)
            }
        }
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 100
    func now() -> TimeInterval { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [SessionEvent] = []
    private var task: Task<Void, Never>?

    init(_ controller: SessionController) {
        let events = controller.events
        task = Task { [weak self] in
            for await e in events { self?.lock.withLock { self?._events.append(e) } }
        }
    }

    deinit { task?.cancel() }

    var events: [SessionEvent] { lock.withLock { _events } }

    func wait(timeout: TimeInterval = 2, _ predicate: ([SessionEvent]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(events) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return predicate(events)
    }

    func expect(timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line,
                _ predicate: ([SessionEvent]) -> Bool) async {
        let ok = await wait(timeout: timeout, predicate)
        XCTAssertTrue(ok, "timed out waiting for expected events: \(events)", file: file, line: line)
    }

    func questions() -> [(Int, String)] {
        events.compactMap { if case .question(let id, let text) = $0 { return (id, text) } else { return nil } }
    }

    func answerText(id: Int) -> String {
        events.compactMap { if case .answerDelta(let i, let t) = $0, i == id { return t } else { return nil } }.joined()
    }
}

// MARK: - Tests

final class SessionControllerTests: XCTestCase {
    struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    private struct Rig {
        let controller: SessionController
        let system: SpyAudioSource
        let mic: SpyAudioSource
        let transcriber: ControlledTranscriber
        let engine: ScriptedEngine
        let clock: TestClock
        let log: EventLog
    }

    private func makeRig(
        engine: ScriptedEngine = ScriptedEngine(tokens: ["A", "B"]),
        system: SpyAudioSource = SpyAudioSource(),
        mic: SpyAudioSource = SpyAudioSource(),
        builder: PromptBuilder = PromptBuilder(resume: "RESUME-TEXT"),
        answerFromMicrophone: Bool = false
    ) -> Rig {
        let transcriber = ControlledTranscriber()
        let clock = TestClock()
        let controller = SessionController(
            systemAudio: system, microphone: mic, transcriber: transcriber,
            answerEngine: engine, promptBuilder: builder,
            flushInterval: 1_000,   // ticks are driven manually
            answerFromMicrophone: answerFromMicrophone,
            now: { clock.now() }
        )
        return Rig(controller: controller, system: system, mic: mic, transcriber: transcriber,
                   engine: engine, clock: clock, log: EventLog(controller))
    }

    /// Pushes a segment and waits until the controller has handled it, so segments from the two
    /// independent streams (interviewer / me) arrive in a deterministic order.
    private func say(_ rig: Rig, _ speaker: Speaker, _ text: String, start: Double = 0, end: Double = 1, final: Bool = true) async {
        rig.transcriber.push(speaker, text, start: start, end: end, final: final)
        await rig.log.expect(hasTranscript(text))
    }

    private func hasTranscript(_ text: String) -> ([SessionEvent]) -> Bool {
        { $0.contains { if case .transcript(let s) = $0 { return s.text == text } else { return false } } }
    }

    func testQuestionMarkProducesQuestionAndStreamedAnswer() async {
        let rig = makeRig()
        await rig.controller.start()
        rig.transcriber.push(.interviewer, "What is a closure?")

        let done = await rig.log.wait { $0.contains(.answerFinished(id: 1)) }
        XCTAssertTrue(done)
        XCTAssertEqual(rig.log.questions().map(\.1), ["What is a closure?"])
        XCTAssertEqual(rig.log.answerText(id: 1), "AB")

        let prompt = try? XCTUnwrap(rig.engine.prompts.first)
        XCTAssertTrue(prompt?.system.contains("RESUME-TEXT") ?? false)
        XCTAssertTrue(prompt?.messages.first?.content.hasSuffix("What is a closure?") ?? false)
        await rig.controller.stop()
    }

    func testSilenceRuleFiresOnTickForQuestionWithoutQuestionMark() async {
        let rig = makeRig()
        await rig.controller.start()
        rig.transcriber.push(.interviewer, "Describe your approach", start: 0, end: 2)
        _ = await rig.log.wait(hasTranscript("Describe your approach"))

        await rig.controller.tick()
        XCTAssertTrue(rig.log.questions().isEmpty, "no silence yet")

        rig.clock.advance(1.0)
        await rig.controller.tick()
        let done = await rig.log.wait { $0.contains(.answerFinished(id: 1)) }
        XCTAssertTrue(done)
        XCTAssertEqual(rig.log.questions().map(\.1), ["Describe your approach"])
        await rig.controller.stop()
    }

    func testNewQuestionSupersedesInFlightAnswer() async {
        let rig = makeRig(engine: ScriptedEngine(tokens: ["partial"], hangs: true))
        await rig.controller.start()

        rig.transcriber.push(.interviewer, "First question?", start: 0, end: 1)
        await rig.log.expect { $0.contains(.answerDelta(id: 1, text: "partial")) }

        rig.transcriber.push(.interviewer, "Second question?", start: 5, end: 6)
        await rig.log.expect { $0.contains(.answerDelta(id: 2, text: "partial")) }

        XCTAssertEqual(rig.log.questions().map(\.0), [1, 2])
        XCTAssertGreaterThanOrEqual(rig.engine.cancelledCount, 1, "first answer stream must be cancelled")
        XCTAssertFalse(rig.log.events.contains(.answerFinished(id: 1)))
        await rig.controller.stop()
    }

    func testMicrophoneSpeechClearsPendingQuestionAndIsLabelled() async {
        let rig = makeRig()
        await rig.controller.start()
        await say(rig, .interviewer, "Describe your approach", start: 0, end: 2)
        await say(rig, .me, "Sure, I would start by", start: 2, end: 3)

        rig.clock.advance(5)
        await rig.controller.tick()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(rig.log.questions().isEmpty)

        let mine = rig.log.events.compactMap { e -> TranscriptSegment? in
            if case .transcript(let s) = e, s.speaker == .me { return s } else { return nil }
        }
        XCTAssertEqual(mine.count, 1)
        await rig.controller.stop()
    }

    func testMicrophoneQuestionIsIgnoredByDefault() async {
        let rig = makeRig()
        await rig.controller.start()
        await say(rig, .me, "What is a closure?")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(rig.log.questions().isEmpty)
        await rig.controller.stop()
    }

    func testMicrophoneQuestionIsAnsweredWhenEnabledAndStaysLabelledAsYou() async {
        let rig = makeRig(answerFromMicrophone: true)
        await rig.controller.start()

        // Punctuated as a statement, no "?": relies on the cue word + silence rule.
        await say(rig, .me, "Расскажи, что такое транзакция.", start: 0, end: 2)
        rig.clock.advance(1.0)
        await rig.controller.tick()

        await rig.log.expect { $0.contains(.answerFinished(id: 1)) }
        XCTAssertEqual(rig.log.questions().map(\.1), ["Расскажи, что такое транзакция."])
        let spoken = rig.log.events.compactMap { e -> TranscriptSegment? in
            if case .transcript(let s) = e { return s } else { return nil }
        }
        XCTAssertEqual(spoken.map(\.speaker), [.me], "the transcript must still say it was you")
        XCTAssertTrue(rig.engine.prompts[0].messages[0].content.hasSuffix("Расскажи, что такое транзакция."))
        await rig.controller.stop()
    }

    func testAnswerNowUsesBufferedSpeechThatHasNoQuestionCue() async {
        let rig = makeRig()
        await rig.controller.start()
        await say(rig, .interviewer, "So, about your PHP experience", start: 0, end: 2)
        XCTAssertTrue(rig.log.questions().isEmpty, "no cue, no question mark: nothing asked yet")

        await rig.controller.askNow()
        await rig.log.expect { $0.contains(.answerFinished(id: 1)) }
        XCTAssertEqual(rig.log.questions().map(\.1), ["So, about your PHP experience"])
        await rig.controller.stop()
    }

    func testAnswerNowIncludesUnfinishedSpeechAndDoesNotAnswerItsFinalTwice() async {
        let rig = makeRig()
        await rig.controller.start()
        await say(rig, .interviewer, "Расскажи про", start: 0, end: 1, final: false)

        await rig.controller.askNow()
        await rig.log.expect { $0.contains(.answerFinished(id: 1)) }
        XCTAssertEqual(rig.log.questions().map(\.1), ["Расскажи про"])

        // The final version of the same utterance arrives afterwards: it is history, not a new question.
        await say(rig, .interviewer, "Расскажи про транзакции?", start: 0, end: 2)
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(rig.log.questions().count, 1)
        await rig.controller.stop()
    }

    func testAnswerNowFallsBackToTheLastThingTheInterviewerSaid() async {
        let rig = makeRig()
        await rig.controller.start()
        await say(rig, .interviewer, "What is a closure?")
        await rig.log.expect { $0.contains(.answerFinished(id: 1)) }

        await rig.controller.askNow()   // nothing pending: regenerate the answer
        await rig.log.expect { $0.contains(.answerFinished(id: 2)) }
        XCTAssertEqual(rig.log.questions().map(\.1), ["What is a closure?", "What is a closure?"])
        await rig.controller.stop()
    }

    func testAnswerNowWithNothingHeardWarns() async {
        let rig = makeRig()
        await rig.controller.start()
        await rig.controller.askNow()
        await rig.log.expect { $0.contains(.warning("Nothing heard yet to answer.")) }
        XCTAssertTrue(rig.log.questions().isEmpty)
        await rig.controller.stop()
    }

    func testAnswerNowIsIgnoredWhenNotRunning() async {
        let rig = makeRig()
        await rig.controller.askNow()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(rig.log.events.isEmpty)
    }

    func testInterimSegmentsAreForwardedButIgnoredForQuestions() async {
        let rig = makeRig()
        await rig.controller.start()
        rig.transcriber.push(.interviewer, "What is", final: false)
        await rig.log.expect(hasTranscript("What is"))
        rig.clock.advance(5)
        await rig.controller.tick()
        XCTAssertTrue(rig.log.questions().isEmpty)
        await rig.controller.stop()
    }

    func testPromptHistoryMergesTurnsAndDoesNotDuplicateTheQuestion() async {
        let rig = makeRig()
        await rig.controller.start()
        await say(rig, .interviewer, "Thanks for joining.", start: 0, end: 1)
        await say(rig, .interviewer, "Welcome to the team call.", start: 1.1, end: 2)   // same speaker → merged turn
        await say(rig, .me, "Happy to be here.", start: 2, end: 3)
        rig.transcriber.push(.interviewer, "Tell me about X?", start: 4, end: 5)

        await rig.log.expect { $0.contains(.answerFinished(id: 1)) }
        let content = rig.engine.prompts[0].messages[0].content
        XCTAssertTrue(content.contains("Interviewer: Thanks for joining. Welcome to the team call."))
        XCTAssertTrue(content.contains("Candidate: Happy to be here."))
        XCTAssertEqual(content.components(separatedBy: "Tell me about X?").count - 1, 1, "question must appear exactly once")
        await rig.controller.stop()
    }

    func testSystemAudioFailureFailsSessionWithoutStartingMic() async {
        let rig = makeRig(system: SpyAudioSource(startError: Boom()))
        await rig.controller.start()
        let state = await rig.controller.state
        XCTAssertEqual(state, .failed("boom"))
        XCTAssertEqual(rig.mic.startCount, 0)
    }

    func testMicrophoneFailureIsOnlyAWarning() async {
        let rig = makeRig(mic: SpyAudioSource(startError: Boom()))
        await rig.controller.start()
        let state = await rig.controller.state
        XCTAssertEqual(state, .running)
        await rig.log.expect { $0.contains(.warning("Microphone unavailable: boom")) }
        await rig.controller.stop()
    }

    func testEssentialTranscriptionFailureFailsSessionAndStopsAudio() async {
        let rig = makeRig()
        await rig.controller.start()
        rig.transcriber.fail(.interviewer, ProviderError.unauthorized)

        await rig.log.expect { $0.contains(.stateChanged(.failed(ProviderError.unauthorized.errorDescription!))) }
        XCTAssertEqual(rig.system.stopCount, 1)
        XCTAssertEqual(rig.mic.stopCount, 1)
    }

    func testMicrophoneTranscriptionFailureKeepsSessionRunning() async {
        let rig = makeRig()
        await rig.controller.start()
        rig.transcriber.fail(.me, Boom())
        await rig.log.expect { $0.contains(.warning("Microphone transcription stopped: boom")) }
        let state = await rig.controller.state
        XCTAssertEqual(state, .running)
        await rig.controller.stop()
    }

    func testSourceStoppedBehavesPerSpeaker() async {
        let rig = makeRig()
        await rig.controller.start()
        await rig.controller.sourceStopped(.me, reason: "unplugged")
        var state = await rig.controller.state
        XCTAssertEqual(state, .running)
        await rig.controller.sourceStopped(.interviewer, reason: "revoked")
        state = await rig.controller.state
        XCTAssertEqual(state, .failed("Audio capture stopped: revoked"))
    }

    func testAnswerFailureIsReported() async {
        let rig = makeRig(engine: ScriptedEngine(tokens: [], failure: ProviderError.http(status: 429, message: "slow down")))
        await rig.controller.start()
        rig.transcriber.push(.interviewer, "Why?")
        await rig.log.expect {
            $0.contains(.answerFailed(id: 1, message: "Request failed (HTTP 429): slow down"))
        }
        let state = await rig.controller.state
        XCTAssertEqual(state, .running, "an LLM error must not end the session")
        await rig.controller.stop()
    }

    func testStopStopsSourcesAndIgnoresLateSegments() async {
        let rig = makeRig()
        await rig.controller.start()
        await rig.controller.stop()
        let state = await rig.controller.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(rig.system.stopCount, 1)
        XCTAssertEqual(rig.mic.stopCount, 1)

        rig.transcriber.push(.interviewer, "Late words?")
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(rig.log.events.contains { if case .transcript = $0 { return true } else { return false } })
    }

    func testStartIsIgnoredWhileRunning() async {
        let rig = makeRig()
        await rig.controller.start()
        await rig.controller.start()
        XCTAssertEqual(rig.system.startCount, 1)
        await rig.controller.stop()
    }

    func testStateChangesAreEmittedInOrder() async {
        let rig = makeRig()
        await rig.controller.start()
        await rig.controller.stop()
        _ = await rig.log.wait { $0.contains(.stateChanged(.idle)) }
        let states = rig.log.events.compactMap { e -> SessionState? in
            if case .stateChanged(let s) = e { return s } else { return nil }
        }
        XCTAssertEqual(states, [.starting, .running, .stopping, .idle])
    }
}
