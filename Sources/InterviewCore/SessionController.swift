import Foundation

public enum SessionState: Equatable, Sendable {
    case idle
    case starting
    case running
    case stopping
    case failed(String)
}

/// Everything the UI needs to render a session. Answer events share the id of their question.
public enum SessionEvent: Equatable, Sendable {
    case stateChanged(SessionState)
    /// Final and interim segments, both speakers.
    case transcript(TranscriptSegment)
    case question(id: Int, text: String)
    case answerDelta(id: Int, text: String)
    case answerFinished(id: Int)
    case answerFailed(id: Int, message: String)
    /// A non-fatal problem (e.g. the microphone is unavailable).
    case warning(String)
}

/// Runs one interview session: audio → transcription → question detection → streamed answer.
///
/// The interviewer's audio (system output) is essential: if it cannot start or its transcription
/// fails, the session fails. The microphone is best-effort and only produces warnings.
/// A new question cancels the answer still streaming for the previous one.
public actor SessionController {
    public nonisolated let events: AsyncStream<SessionEvent>
    private nonisolated let eventContinuation: AsyncStream<SessionEvent>.Continuation

    public private(set) var state: SessionState = .idle

    private let systemAudio: AudioSource
    private let microphone: AudioSource?
    private let transcriber: Transcriber
    private let answerEngine: AnswerEngine
    /// Reads screenshots; falls back to `answerEngine` when the provider's usual model can see images.
    private let visionEngine: AnswerEngine?
    private let promptBuilder: PromptBuilder
    private let detectorTemplate: QuestionDetector
    private let flushInterval: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let maxHistoryTurns: Int
    private let answerFromMicrophone: Bool

    private var detector: QuestionDetector
    private var turns: [Turn] = []
    private var transcriptionTasks: [Task<Void, Never>] = []
    private var tickerTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    private var currentQuestionID = 0

    // Bridges segment (audio) time to wall time for the silence rule.
    private var lastInterviewerEnd: TimeInterval?
    private var lastInterviewerWall: TimeInterval = 0

    // "Answer now" support: what is being said right now, and whether its final version was already used.
    private var interimText: String?
    private var skipNextInterviewerFinal = false

    public init(
        systemAudio: AudioSource,
        microphone: AudioSource?,
        transcriber: Transcriber,
        answerEngine: AnswerEngine,
        visionEngine: AnswerEngine? = nil,
        promptBuilder: PromptBuilder,
        detector: QuestionDetector = QuestionDetector(),
        flushInterval: TimeInterval = 0.2,
        maxHistoryTurns: Int = 20,
        answerFromMicrophone: Bool = false,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.transcriber = transcriber
        self.answerEngine = answerEngine
        self.visionEngine = visionEngine
        self.promptBuilder = promptBuilder
        self.detectorTemplate = detector
        self.detector = detector
        self.flushInterval = flushInterval
        self.maxHistoryTurns = maxHistoryTurns
        self.answerFromMicrophone = answerFromMicrophone
        self.now = now
        (events, eventContinuation) = AsyncStream.makeStream(of: SessionEvent.self, bufferingPolicy: .unbounded)
    }

    // MARK: Lifecycle

    public func start() async {
        switch state {
        case .idle, .failed: break
        default: return
        }
        detector = detectorTemplate
        turns = []
        lastInterviewerEnd = nil
        interimText = nil
        skipNextInterviewerFinal = false
        setState(.starting)

        do {
            let stream = try await systemAudio.start()
            guard state == .starting else { await teardown(); return }
            launchTranscription(audio: stream, speaker: .interviewer, essential: true)
        } catch {
            await fail(describe(error))
            return
        }

        if let microphone {
            do {
                let stream = try await microphone.start()
                guard state == .starting else { await teardown(); return }
                launchTranscription(audio: stream, speaker: .me, essential: false)
            } catch {
                eventContinuation.yield(.warning(L10n.tr("Microphone unavailable: %@", describe(error))))
            }
        }

        let interval = flushInterval
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(0.005, interval) * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.tick()
            }
        }
        setState(.running)
    }

    public func stop() async {
        switch state {
        case .idle, .stopping: return
        default: break
        }
        setState(.stopping)
        await teardown()
        setState(.idle)
    }

    /// For capture sources that stop on their own (permission revoked, device lost).
    public func sourceStopped(_ speaker: Speaker, reason: String) async {
        guard state == .running else { return }
        if speaker == .interviewer {
            await fail(L10n.tr("Audio capture stopped: %@", reason))
        } else {
            eventContinuation.yield(.warning(L10n.tr("Microphone stopped: %@", reason)))
        }
    }

    // MARK: Pipeline

    private func launchTranscription(audio: AsyncStream<PCMChunk>, speaker: Speaker, essential: Bool) {
        let transcriber = transcriber
        let task = Task { [weak self] in
            do {
                for try await segment in transcriber.transcribe(audio: audio, speaker: speaker) {
                    await self?.handle(segment)
                }
            } catch {
                if !Task.isCancelled {
                    await self?.transcriptionFailed(speaker: speaker, essential: essential, error: error)
                }
            }
        }
        transcriptionTasks.append(task)
    }

    private func transcriptionFailed(speaker: Speaker, essential: Bool, error: Error) async {
        guard state == .running || state == .starting else { return }
        if essential {
            await fail(describe(error))
        } else {
            eventContinuation.yield(.warning(L10n.tr("Microphone transcription stopped: %@", describe(error))))
        }
    }

    private func handle(_ segment: TranscriptSegment) {
        guard state == .running else { return }
        // The transcript always shows who really spoke.
        eventContinuation.yield(.transcript(segment))

        // Test / in-room mode: the user's own voice is treated as the interviewer's question.
        var effective = segment
        if segment.speaker == .me && answerFromMicrophone {
            effective = TranscriptSegment(speaker: .interviewer, text: segment.text, isFinal: segment.isFinal,
                                          start: segment.start, end: segment.end)
        }

        guard segment.isFinal else {
            if effective.speaker == .interviewer { interimText = effective.text }
            return
        }

        appendTurn(speaker: effective.speaker, text: effective.text)
        if effective.speaker == .interviewer {
            interimText = nil
            lastInterviewerEnd = effective.end
            lastInterviewerWall = now()
            // The user already asked for this very utterance with "answer now"; don't answer it twice.
            if skipNextInterviewerFinal {
                skipNextInterviewerFinal = false
                _ = detector.takePending()
                return
            }
        }
        if let question = detector.ingest(effective) {
            ask(question)
        }
    }

    /// Answers immediately with what the interviewer has just said, without waiting for the
    /// question detector: unfinished speech first, then buffered speech, then the last thing heard.
    public func askNow() {
        guard state == .running else { return }
        let pending = detector.takePending()
        let interim = interimText?.trimmingCharacters(in: .whitespacesAndNewlines)
        interimText = nil

        let combined = [pending, interim]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !combined.isEmpty {
            if let interim, !interim.isEmpty { skipNextInterviewerFinal = true }
            ask(DetectedQuestion(text: combined))
        } else if let last = turns.last(where: { $0.speaker == .interviewer }) {
            ask(DetectedQuestion(text: last.text))   // re-answer the most recent question
        } else {
            eventContinuation.yield(.warning(L10n.tr("Nothing heard yet to answer.")))
        }
    }

    /// Answers a question the user typed. The recent conversation is context as it stands:
    /// unlike a detected question, the text is not one of the interviewer's turns.
    public func ask(typed text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state == .running, !question.isEmpty else { return }
        let prompt = promptBuilder.build(question: question, history: turns)
        answer(label: question, prompt: prompt, engine: answerEngine)
    }

    /// Applies the detector's silence rule. Public for tests and for manual nudging.
    func tick() {
        guard state == .running, let lastEnd = lastInterviewerEnd else { return }
        let streamNow = lastEnd + (now() - lastInterviewerWall)
        if let question = detector.flush(now: streamNow) {
            ask(question)
        }
    }

    /// Answers what a screenshot shows (a coding task, an error, a quiz). The JPEG comes from the app.
    public func answerScreen(jpeg: Data) {
        guard state == .running else { return }
        let prompt = promptBuilder.buildScreen(history: turns, imageJPEG: jpeg)
        answer(label: L10n.tr("Screenshot of your screen"), prompt: prompt, engine: visionEngine ?? answerEngine)
    }

    private func ask(_ question: DetectedQuestion) {
        let prompt = promptBuilder.build(question: question.text, history: historyForPrompt())
        answer(label: question.text, prompt: prompt, engine: answerEngine)
    }

    private func answer(label: String, prompt: AnswerPrompt, engine: AnswerEngine) {
        answerTask?.cancel()
        currentQuestionID += 1
        let id = currentQuestionID
        eventContinuation.yield(.question(id: id, text: label))
        answerTask = Task { [weak self] in
            do {
                for try await token in engine.answer(for: prompt) {
                    await self?.deliver(id: id, token: token)
                }
                await self?.finishAnswer(id: id)
            } catch {
                if !Task.isCancelled {
                    await self?.failAnswer(id: id, error: error)
                }
            }
        }
    }

    // Stale answers (superseded by a newer question) are dropped by id.
    private func deliver(id: Int, token: String) {
        guard id == currentQuestionID, state == .running else { return }
        eventContinuation.yield(.answerDelta(id: id, text: token))
    }

    private func finishAnswer(id: Int) {
        guard id == currentQuestionID, state == .running else { return }
        eventContinuation.yield(.answerFinished(id: id))
    }

    private func failAnswer(id: Int, error: Error) {
        guard id == currentQuestionID, state == .running else { return }
        eventContinuation.yield(.answerFailed(id: id, message: describe(error)))
    }

    // MARK: History

    private func appendTurn(speaker: Speaker, text: String) {
        if let last = turns.last, last.speaker == speaker {
            turns[turns.count - 1] = Turn(speaker: speaker, text: last.text + " " + text)
        } else {
            turns.append(Turn(speaker: speaker, text: text))
        }
        if turns.count > maxHistoryTurns { turns.removeFirst(turns.count - maxHistoryTurns) }
    }

    /// The question itself is the trailing interviewer turn; the prompt states it separately.
    private func historyForPrompt() -> [Turn] {
        guard let last = turns.last, last.speaker == .interviewer else { return turns }
        return Array(turns.dropLast())
    }

    // MARK: Helpers

    private func setState(_ new: SessionState) {
        guard state != new else { return }
        state = new
        eventContinuation.yield(.stateChanged(new))
    }

    private func fail(_ message: String) async {
        await teardown()
        setState(.failed(message))
    }

    private func teardown() async {
        tickerTask?.cancel()
        tickerTask = nil
        answerTask?.cancel()
        answerTask = nil
        for task in transcriptionTasks { task.cancel() }
        transcriptionTasks = []
        await systemAudio.stop()
        await microphone?.stop()
    }

    private nonisolated func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
