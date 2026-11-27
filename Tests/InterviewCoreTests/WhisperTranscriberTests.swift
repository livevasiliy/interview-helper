import XCTest
@testable import InterviewCore

private func chunk(level: Int16, seconds: Double) -> PCMChunk {
    let frames = Int(seconds * 16_000)
    var data = Data(capacity: frames * 2)
    for i in 0..<frames {
        // Alternating sign keeps the RMS equal to |level|.
        let v = (i % 2 == 0) ? level : -level
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }
    return PCMChunk(data: data)
}

final class UtteranceSegmenterTests: XCTestCase {
    private let loud: Int16 = 6_000      // ~0.18
    private let quiet: Int16 = 30        // ~0.001

    private func run(_ steps: [(Int16, Double)], _ segmenter: UtteranceSegmenter = UtteranceSegmenter()) -> [UtteranceSegmenter.Utterance] {
        var s = segmenter
        var out: [UtteranceSegmenter.Utterance] = []
        for (level, seconds) in steps {
            // Feed in 100 ms pieces like a real capture.
            for _ in 0..<Int((seconds * 10).rounded()) {
                if let u = s.feed(chunk(level: level, seconds: 0.1)) { out.append(u) }
            }
        }
        if let rest = s.finish() { out.append(rest) }
        return out
    }

    func testSilenceAloneProducesNothing() {
        XCTAssertTrue(run([(quiet, 3)]).isEmpty)
    }

    func testSpeechEndsAfterSilence() {
        let result = run([(quiet, 1), (loud, 1.5), (quiet, 1.5)])
        XCTAssertEqual(result.count, 1)
        let u = result[0]
        // Starts a little before the speech (pre-roll), ends after the silence window.
        XCTAssertEqual(u.start, 0.8, accuracy: 0.11)
        XCTAssertEqual(u.end, 3.2, accuracy: 0.11)
        XCTAssertGreaterThan(u.pcm.count, 1_000)
    }

    func testTwoPhrasesAreSeparated() {
        let result = run([(loud, 1), (quiet, 1), (loud, 1), (quiet, 1)])
        XCTAssertEqual(result.count, 2)
        XCTAssertLessThan(result[0].end, result[1].start + 0.01)
    }

    func testShortBurstIsDropped() {
        XCTAssertTrue(run([(quiet, 1), (loud, 0.1), (quiet, 2)]).isEmpty)
    }

    func testShortPauseInsideAPhraseDoesNotSplit() {
        XCTAssertEqual(run([(loud, 1), (quiet, 0.3), (loud, 1), (quiet, 1)]).count, 1)
    }

    func testLongMonologueIsCut() {
        let result = run([(loud, 25), (quiet, 1)], UtteranceSegmenter(maxUtterance: 10))
        XCTAssertGreaterThanOrEqual(result.count, 2)
    }

    func testFinishFlushesUnfinishedSpeech() {
        XCTAssertEqual(run([(loud, 1)]).count, 1)
    }
}

final class WhisperTranscriberTests: XCTestCase {
    private let base = URL(string: "https://api.example.com/openai/v1")!

    private func audio(_ steps: [(Int16, Double)]) -> AsyncStream<PCMChunk> {
        AsyncStream { continuation in
            for (level, seconds) in steps {
                for _ in 0..<Int((seconds * 10).rounded()) { continuation.yield(chunk(level: level, seconds: 0.1)) }
            }
            continuation.finish()
        }
    }

    func testRequestIsMultipartWithModelLanguageAndWav() throws {
        let transcriber = WhisperTranscriber(
            configuration: WhisperConfiguration(baseURL: base, apiKey: "k", model: "whisper-x", language: "ru"),
            session: StubURLProtocol.session()
        )
        let u = UtteranceSegmenter.Utterance(pcm: Data(repeating: 1, count: 640), start: 1, end: 2)
        let request = transcriber.makeRequest(for: u, boundary: "BOUND")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer k")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "multipart/form-data; boundary=BOUND")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nwhisper-x"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nru"))
        XCTAssertTrue(body.contains("filename=\"speech.wav\""))
        XCTAssertTrue(body.contains("RIFF"))
    }

    func testLanguageFieldIsOmittedForAutoDetect() throws {
        let transcriber = WhisperTranscriber(configuration: WhisperConfiguration(baseURL: base, apiKey: "k", model: "m"))
        let u = UtteranceSegmenter.Utterance(pcm: Data(repeating: 1, count: 64), start: 0, end: 1)
        let body = String(decoding: try XCTUnwrap(transcriber.makeRequest(for: u).httpBody), as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"language\""))
    }

    func testTranscribesAnUtteranceIntoAFinalSegment() async throws {
        StubURLProtocol.reset(chunks: [#"{"text":" Что такое транзакция? "}"#])
        let transcriber = WhisperTranscriber(
            configuration: WhisperConfiguration(baseURL: base, apiKey: "k", model: "m"),
            session: StubURLProtocol.session()
        )
        var segments: [TranscriptSegment] = []
        for try await segment in transcriber.transcribe(audio: audio([(6_000, 1.5), (30, 1.5)]), speaker: .interviewer) {
            segments.append(segment)
        }
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Что такое транзакция?")
        XCTAssertTrue(segments[0].isFinal)
        XCTAssertEqual(segments[0].speaker, .interviewer)
        XCTAssertGreaterThan(segments[0].end, segments[0].start)
    }

    func testRejectedKeyEndsTheStreamWithUnauthorized() async {
        StubURLProtocol.reset(status: 401, chunks: [#"{"error":{"message":"bad key"}}"#])
        let transcriber = WhisperTranscriber(
            configuration: WhisperConfiguration(baseURL: base, apiKey: "bad", model: "m"),
            session: StubURLProtocol.session()
        )
        do {
            for try await _ in transcriber.transcribe(audio: audio([(6_000, 1.5), (30, 1.5)]), speaker: .me) {}
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unauthorized)
        }
    }

    func testRepeatedServerErrorsEndTheStream() async {
        StubURLProtocol.reset(status: 500, chunks: [#"{"error":{"message":"boom"}}"#])
        let transcriber = WhisperTranscriber(
            configuration: WhisperConfiguration(baseURL: base, apiKey: "k", model: "m", maxConsecutiveFailures: 2),
            session: StubURLProtocol.session()
        )
        do {
            let steps: [(Int16, Double)] = [(6_000, 1), (30, 1), (6_000, 1), (30, 1)]
            for try await _ in transcriber.transcribe(audio: audio(steps), speaker: .me) {}
            XCTFail("expected an error")
        } catch {
            guard case .http(let status, _) = error as? ProviderError else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 500)
        }
    }
}

final class TranscriptionProviderTests: XCTestCase {
    func testKeysAreSharedWithTheMatchingAnswerProvider() {
        XCTAssertEqual(TranscriptionProvider.groq.secretKey, AnswerProvider.groq.secretKey)
        XCTAssertEqual(TranscriptionProvider.openAI.secretKey, AnswerProvider.openAI.secretKey)
        XCTAssertEqual(TranscriptionProvider.deepgram.secretKey, .deepgramAPIKey)
    }

    func testSettingsDefaultsAndOverrides() throws {
        var s = AppSettings()
        XCTAssertEqual(s.transcriptionProvider, .deepgram)
        XCTAssertEqual(s.transcriptionModelName(for: .groq), "whisper-large-v3-turbo")
        s.setTranscriptionModelName("  whisper-large-v3 ", for: .groq)
        XCTAssertEqual(s.transcriptionModelName(for: .groq), "whisper-large-v3")
        s.transcriptionProvider = .groq
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), s)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).transcriptionProvider, .deepgram)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"transcriptionProvider":"x"}"#.utf8)).transcriptionProvider, .deepgram)
    }

    func testSetupNeedsTheChosenTranscriptionKey() throws {
        let secrets = InMemorySecretStore()
        try secrets.set("g", for: .geminiAPIKey)
        try secrets.set("d", for: .deepgramAPIKey)
        let perms = FakePermissionsService(microphone: .granted, screenRecording: .granted)
        XCTAssertTrue(SetupState.current(permissions: perms, secrets: secrets).isReady)
        XCTAssertEqual(SetupState.current(permissions: perms, secrets: secrets, transcription: .groq).missing, [.transcriptionKey])
        try secrets.set("q", for: .groqAPIKey)
        XCTAssertTrue(SetupState.current(permissions: perms, secrets: secrets, transcription: .groq).isReady)
    }
}

final class ScreenshotPromptTests: XCTestCase {
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])

    func testScreenPromptCarriesTheImageAndTheTask() {
        let p = PromptBuilder(resume: "6 years PHP", roleContext: "PHP and React interview", language: "Russian")
            .buildScreen(history: [Turn(speaker: .interviewer, text: "Solve the task on screen")], imageJPEG: jpeg)
        XCTAssertEqual(p.imageJPEG, jpeg)
        XCTAssertTrue(p.system.contains("fenced code block"))
        XCTAssertTrue(p.system.contains("PHP and React interview"))
        XCTAssertTrue(p.system.contains("6 years PHP"))
        XCTAssertTrue(p.system.contains("Russian"))
        XCTAssertTrue(p.messages[0].content.contains("Interviewer: Solve the task on screen"))
    }

    func testOpenAIEngineSendsTheImageAsADataURL() throws {
        let engine = OpenAICompatibleAnswerEngine(baseURL: URL(string: "https://x.test/v1")!, apiKey: "k", model: "m")
        let prompt = AnswerPrompt(system: "s", messages: [PromptMessage(role: .user, content: "look")], imageJPEG: jpeg)
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(engine.makeRequest(for: prompt).httpBody)) as? [String: Any]
        let messages = try XCTUnwrap(body?["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["type"] as? String, "text")
        let url = (content[1]["image_url"] as? [String: Any])?["url"] as? String
        XCTAssertEqual(url, "data:image/jpeg;base64," + jpeg.base64EncodedString())
    }

    func testAnthropicEngineSendsTheImageAsABase64Block() throws {
        let engine = AnthropicAnswerEngine(apiKey: "k")
        let prompt = AnswerPrompt(system: "s", messages: [PromptMessage(role: .user, content: "look")], imageJPEG: jpeg)
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(engine.makeRequest(for: prompt).httpBody)) as? [String: Any]
        let messages = try XCTUnwrap(body?["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["type"] as? String, "image")
        XCTAssertEqual((content[0]["source"] as? [String: Any])?["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(content[1]["text"] as? String, "look")
    }

    func testTextOnlyPromptStillUsesPlainStringContent() throws {
        let engine = OpenAICompatibleAnswerEngine(baseURL: URL(string: "https://x.test/v1")!, apiKey: "k", model: "m")
        let prompt = AnswerPrompt(system: "s", messages: [PromptMessage(role: .user, content: "hi")])
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(engine.makeRequest(for: prompt).httpBody)) as? [String: Any]
        XCTAssertEqual((body?["messages"] as? [[String: Any]])?.last?["content"] as? String, "hi")
    }

    func testVisionModelSelection() {
        var s = AppSettings()
        XCTAssertEqual(s.visionModelName(for: .gemini), s.modelName(for: .gemini), "Gemini models accept images")
        XCTAssertEqual(s.visionModelName(for: .groq), AnswerProvider.groq.visionModel)
        s.setVisionModelName("my-vision", for: .groq)
        XCTAssertEqual(s.visionModelName(for: .groq), "my-vision")
    }

    func testScreenshotAnswerStreamsThroughTheController() async {
        let vision = ScriptedEngine(tokens: ["```php\n", "echo 1;\n", "```"])
        let text = ScriptedEngine(tokens: ["wrong engine"])
        let controller = SessionController(
            systemAudio: SpyAudioSource(), microphone: nil, transcriber: ControlledTranscriber(),
            answerEngine: text, visionEngine: vision, promptBuilder: PromptBuilder()
        )
        let log = EventLog(controller)
        await controller.start()
        await log.expect { $0.contains { if case .stateChanged(.running) = $0 { return true } else { return false } } }
        await controller.answerScreen(jpeg: jpeg)
        await log.expect { $0.contains { if case .answerFinished = $0 { return true } else { return false } } }
        XCTAssertEqual(log.answerText(id: 1), "```php\necho 1;\n```")
        XCTAssertEqual(vision.prompts.first?.imageJPEG, jpeg)
        XCTAssertTrue(text.prompts.isEmpty)
        await controller.stop()
    }
}
