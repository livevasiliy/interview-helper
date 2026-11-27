import Foundation

public struct DeepgramConfiguration: Sendable {
    public var apiKey: String
    public var model: String
    /// `multi` enables multilingual code-switching on Nova-3. Override with e.g. "en" or "ru".
    public var language: String
    public var endpointingMilliseconds: Int
    public var baseURL: URL
    /// Delays before each successive reconnect attempt; its length is the retry budget.
    public var retryDelays: [TimeInterval]
    public var keepAliveInterval: TimeInterval
    /// How long to wait for the server to flush final results after `CloseStream`.
    public var closeGrace: TimeInterval

    public init(
        apiKey: String,
        model: String = "nova-3",
        language: String = "multi",
        endpointingMilliseconds: Int = 300,
        baseURL: URL = URL(string: "wss://api.deepgram.com/v1/listen")!,
        retryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8],
        keepAliveInterval: TimeInterval = 5,
        closeGrace: TimeInterval = 2
    ) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.endpointingMilliseconds = endpointingMilliseconds
        self.baseURL = baseURL
        self.retryDelays = retryDelays
        self.keepAliveInterval = keepAliveInterval
        self.closeGrace = closeGrace
    }

    func makeRequest() -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "endpointing", value: String(endpointingMilliseconds)),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }
}

enum DeepgramMessage {
    private struct Payload: Decodable {
        struct Channel: Decodable {
            struct Alternative: Decodable { let transcript: String }
            let alternatives: [Alternative]
        }
        let type: String?
        let is_final: Bool?
        let start: Double?
        let duration: Double?
        let channel: Channel?
    }

    /// Turns a `Results` message into a segment; everything else (metadata, empty text) is nil.
    static func segment(from text: String, speaker: Speaker, offset: TimeInterval) -> TranscriptSegment? {
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.type == "Results",
              let transcript = payload.channel?.alternatives.first?.transcript
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !transcript.isEmpty
        else { return nil }

        let start = offset + (payload.start ?? 0)
        return TranscriptSegment(
            speaker: speaker,
            text: transcript,
            isFinal: payload.is_final ?? false,
            start: start,
            end: start + (payload.duration ?? 0)
        )
    }
}

/// Streaming speech-to-text over Deepgram's WebSocket API (ADR-002).
///
/// One socket per `transcribe` call. If the socket drops it reconnects with backoff while
/// audio keeps flowing; audio produced during an outage is dropped. A rejected API key is
/// fatal (no retries). Segment timestamps stay monotonic across reconnects.
public struct DeepgramTranscriber: Transcriber {
    public let configuration: DeepgramConfiguration
    public let connector: WebSocketConnector

    public init(configuration: DeepgramConfiguration, connector: WebSocketConnector = URLSessionWebSocketConnector()) {
        self.configuration = configuration
        self.connector = connector
    }

    public func transcribe(audio: AsyncStream<PCMChunk>, speaker: Speaker) -> AsyncThrowingStream<TranscriptSegment, Error> {
        let configuration = configuration
        let connector = connector
        return AsyncThrowingStream { continuation in
            let task = Task {
                let session = DeepgramSession(configuration: configuration, connector: connector, speaker: speaker)
                do {
                    try await session.run(audio: audio, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private final class DeepgramSession: @unchecked Sendable {
    private let configuration: DeepgramConfiguration
    private let connector: WebSocketConnector
    private let speaker: Speaker

    private let lock = NSLock()
    private var current: WebSocketConnection?
    private var audioEnded = false

    // Only touched from `run`.
    private var timeOffset: TimeInterval = 0
    private var maxEnd: TimeInterval = 0

    init(configuration: DeepgramConfiguration, connector: WebSocketConnector, speaker: Speaker) {
        self.configuration = configuration
        self.connector = connector
        self.speaker = speaker
    }

    func run(audio: AsyncStream<PCMChunk>, continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation) async throws {
        var attempt = 0
        var pump: Task<Void, Never>?
        var keepAlive: Task<Void, Never>?
        defer {
            pump?.cancel()
            keepAlive?.cancel()
            closeCurrent()
        }

        while !Task.isCancelled && !isAudioEnded() {
            let connection: WebSocketConnection
            do {
                connection = try await connector.connect(configuration.makeRequest())
            } catch {
                try await backoff(&attempt, after: error)
                continue
            }
            setCurrent(connection)

            // Start feeding audio only once the first connection exists, so early audio
            // waits in the source's buffer instead of being dropped.
            if pump == nil {
                pump = Task { await self.pumpAudio(audio) }
                keepAlive = Task { await self.keepAliveLoop() }
            }

            do {
                while true {
                    let message = try await withTaskCancellationHandler {
                        try await connection.receive()
                    } onCancel: {
                        connection.close()
                    }
                    attempt = 0
                    if case .text(let text) = message,
                       let segment = DeepgramMessage.segment(from: text, speaker: speaker, offset: timeOffset) {
                        maxEnd = max(maxEnd, segment.end)
                        continuation.yield(segment)
                    }
                }
            } catch {
                clearCurrent()
                connection.close()
                if Task.isCancelled || isAudioEnded() { return }
                if let status = connection.failureStatusCode, status == 401 || status == 403 {
                    throw ProviderError.unauthorized
                }
                timeOffset = maxEnd
                try await backoff(&attempt, after: error)
            }
        }
    }

    private func backoff(_ attempt: inout Int, after error: Error) async throws {
        guard attempt < configuration.retryDelays.count else {
            throw ProviderError.connectionFailed(error.localizedDescription)
        }
        let delay = configuration.retryDelays[attempt]
        attempt += 1
        try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
    }

    private func pumpAudio(_ audio: AsyncStream<PCMChunk>) async {
        for await chunk in audio {
            if Task.isCancelled { return }
            if let connection = currentConnection() {
                try? await connection.send(chunk.data)
            }
        }
        if Task.isCancelled { return }
        markAudioEnded()
        guard let connection = currentConnection() else { return }
        try? await connection.send(#"{"type":"CloseStream"}"#)
        // Give the server a moment to flush final results, then close; the receive loop ends.
        try? await Task.sleep(nanoseconds: UInt64(max(0, configuration.closeGrace) * 1_000_000_000))
        connection.close()
    }

    private func keepAliveLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0.01, configuration.keepAliveInterval) * 1_000_000_000))
            } catch { return }
            if let connection = currentConnection() {
                try? await connection.send(#"{"type":"KeepAlive"}"#)
            }
        }
    }

    // MARK: State (synchronous helpers keep NSLock out of async functions)

    private func currentConnection() -> WebSocketConnection? { lock.withLock { current } }
    private func setCurrent(_ c: WebSocketConnection) { lock.withLock { current = c } }
    private func clearCurrent() { lock.withLock { current = nil } }
    private func isAudioEnded() -> Bool { lock.withLock { audioEnded } }
    private func markAudioEnded() { lock.withLock { audioEnded = true } }
    private func closeCurrent() { lock.withLock { current }?.close() }
}
