import Foundation

public struct WhisperConfiguration: Sendable {
    public var baseURL: URL
    public var apiKey: String
    public var model: String
    /// ISO 639-1 code (`ru`, `en`); nil lets the model detect the language.
    public var language: String?
    /// Consecutive failed uploads before the transcription is given up (a bad key stops it at once).
    public var maxConsecutiveFailures: Int
    public var segmenter: UtteranceSegmenter

    public init(
        baseURL: URL,
        apiKey: String,
        model: String,
        language: String? = nil,
        maxConsecutiveFailures: Int = 3,
        segmenter: UtteranceSegmenter = UtteranceSegmenter()
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.segmenter = segmenter
    }
}

/// Cuts a continuous audio stream into utterances by silence, using the audio clock for timestamps.
/// Pure value type: feed it chunks, it hands back finished utterances.
public struct UtteranceSegmenter: Sendable, Equatable {
    public struct Utterance: Sendable, Equatable {
        public let pcm: Data
        public let start: TimeInterval
        public let end: TimeInterval
    }

    /// RMS level above which a chunk counts as speech.
    public var speechThreshold: Float
    /// Silence that ends an utterance.
    public var silenceToEnd: TimeInterval
    /// Shorter bursts (clicks, coughs) are dropped.
    public var minSpeech: TimeInterval
    /// Long monologues are cut here so a request never grows without bound.
    public var maxUtterance: TimeInterval
    /// Audio kept from before the speech started, so the first syllable is not clipped.
    public var preRoll: TimeInterval

    private var clock: TimeInterval = 0
    private var inSpeech = false
    private var buffer = Data()
    private var bufferStart: TimeInterval = 0
    private var speechDuration: TimeInterval = 0
    private var silenceDuration: TimeInterval = 0
    private var recent = Data()          // trailing quiet audio waiting to become pre-roll
    private var recentDuration: TimeInterval = 0
    private var sampleRate = 16_000

    public init(
        speechThreshold: Float = 0.012,
        silenceToEnd: TimeInterval = 0.7,
        minSpeech: TimeInterval = 0.35,
        maxUtterance: TimeInterval = 20,
        preRoll: TimeInterval = 0.25
    ) {
        self.speechThreshold = speechThreshold
        self.silenceToEnd = silenceToEnd
        self.minSpeech = minSpeech
        self.maxUtterance = maxUtterance
        self.preRoll = preRoll
    }

    public mutating func feed(_ chunk: PCMChunk) -> Utterance? {
        let duration = chunk.duration
        guard duration > 0 else { return nil }
        sampleRate = chunk.sampleRate
        defer { clock += duration }
        let loud = chunk.rmsLevel > speechThreshold

        if !inSpeech {
            guard loud else {
                recent.append(chunk.data)
                recentDuration += duration
                trimRecent()
                return nil
            }
            inSpeech = true
            bufferStart = clock - recentDuration
            buffer = recent
            buffer.append(chunk.data)
            recent = Data()
            recentDuration = 0
            speechDuration = duration
            silenceDuration = 0
            return nil
        }

        buffer.append(chunk.data)
        if loud {
            speechDuration += duration
            silenceDuration = 0
        } else {
            silenceDuration += duration
        }
        let total = Double(buffer.count / MemoryLayout<Int16>.size) / Double(sampleRate)
        if silenceDuration >= silenceToEnd || total >= maxUtterance {
            return emit(end: clock + duration)
        }
        return nil
    }

    /// Flushes what is left when the audio ends.
    public mutating func finish() -> Utterance? {
        inSpeech ? emit(end: clock) : nil
    }

    private mutating func emit(end: TimeInterval) -> Utterance? {
        defer {
            inSpeech = false
            buffer = Data()
            speechDuration = 0
            silenceDuration = 0
        }
        guard speechDuration >= minSpeech else { return nil }
        return Utterance(pcm: buffer, start: bufferStart, end: end)
    }

    private mutating func trimRecent() {
        let bytesPerSecond = sampleRate * MemoryLayout<Int16>.size
        let keep = Int(preRoll * Double(bytesPerSecond)) & ~1
        if recent.count > keep {
            recent = Data(recent.suffix(keep))
            recentDuration = Double(recent.count / MemoryLayout<Int16>.size) / Double(sampleRate)
        }
    }
}

/// Speech-to-text for providers with an OpenAI-style `/audio/transcriptions` endpoint (Groq, OpenAI).
/// Not streaming: each utterance (cut by `UtteranceSegmenter`) is uploaded when it ends and comes back
/// as one final segment. Uploads run one at a time, in order.
public struct WhisperTranscriber: Transcriber, @unchecked Sendable {
    public let configuration: WhisperConfiguration
    private let session: URLSession

    public init(configuration: WhisperConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func transcribe(audio: AsyncStream<PCMChunk>, speaker: Speaker) -> AsyncThrowingStream<TranscriptSegment, Error> {
        let configuration = configuration
        let session = session
        let client = self
        return AsyncThrowingStream { continuation in
            let (utterances, utteranceSink) = AsyncStream.makeStream(of: UtteranceSegmenter.Utterance.self, bufferingPolicy: .unbounded)

            let cutter = Task {
                var segmenter = configuration.segmenter
                for await chunk in audio {
                    if Task.isCancelled { break }
                    if let utterance = segmenter.feed(chunk) { utteranceSink.yield(utterance) }
                }
                if let rest = segmenter.finish() { utteranceSink.yield(rest) }
                utteranceSink.finish()
            }

            let worker = Task {
                var failures = 0
                for await utterance in utterances {
                    if Task.isCancelled { break }
                    do {
                        let text = try await client.upload(utterance, session: session)
                        failures = 0
                        guard !text.isEmpty else { continue }
                        continuation.yield(TranscriptSegment(
                            speaker: speaker, text: text, isFinal: true, start: utterance.start, end: utterance.end
                        ))
                    } catch is CancellationError {
                        break
                    } catch ProviderError.unauthorized {
                        continuation.finish(throwing: ProviderError.unauthorized)
                        cutter.cancel()
                        return
                    } catch {
                        failures += 1
                        if failures >= configuration.maxConsecutiveFailures {
                            continuation.finish(throwing: error)
                            cutter.cancel()
                            return
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                cutter.cancel()
                worker.cancel()
                utteranceSink.finish()
            }
        }
    }

    func makeRequest(for utterance: UtteranceSegmenter.Utterance, boundary: String = UUID().uuidString) -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", configuration.model)
        field("response_format", "json")
        field("temperature", "0")
        if let language = configuration.language { field("language", language) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(WAV.data(pcm: utterance.pcm))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    /// One upload; a rate limit (429) gets a single retry after a short wait.
    func upload(_ utterance: UtteranceSegmenter.Utterance, session: URLSession) async throws -> String {
        for attempt in 0..<2 {
            let (data, response) = try await session.data(for: makeRequest(for: utterance))
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.connectionFailed(L10n.tr("No HTTP response"))
            }
            if http.statusCode == 429, attempt == 0 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            guard http.statusCode == 200 else { throw ProviderError.fromHTTP(status: http.statusCode, body: data) }
            struct Reply: Decodable { let text: String? }
            let text = (try? JSONDecoder().decode(Reply.self, from: data))?.text ?? ""
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw ProviderError.connectionFailed(L10n.tr("Too many requests"))
    }
}
