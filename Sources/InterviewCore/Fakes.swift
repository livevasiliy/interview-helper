import Foundation

/// Test double: ignores audio, replays scripted segments, optionally fails afterwards.
public struct FakeTranscriber: Transcriber {
    public let script: [TranscriptSegment]
    public let failure: (any Error)?

    public init(script: [TranscriptSegment], failure: (any Error)? = nil) {
        self.script = script
        self.failure = failure
    }

    public func transcribe(audio: AsyncStream<PCMChunk>, speaker: Speaker) -> AsyncThrowingStream<TranscriptSegment, Error> {
        let script = script
        let failure = failure
        return AsyncThrowingStream { continuation in
            for segment in script where segment.speaker == speaker {
                continuation.yield(segment)
            }
            continuation.finish(throwing: failure)
        }
    }
}

/// Test double: replays scripted tokens.
public struct FakeAnswerEngine: AnswerEngine {
    public let tokens: [String]
    public let failure: (any Error)?

    public init(tokens: [String], failure: (any Error)? = nil) {
        self.tokens = tokens
        self.failure = failure
    }

    public func answer(for prompt: AnswerPrompt) -> AsyncThrowingStream<String, Error> {
        let tokens = tokens
        let failure = failure
        return AsyncThrowingStream { continuation in
            for token in tokens { continuation.yield(token) }
            continuation.finish(throwing: failure)
        }
    }
}

/// Test double: yields scripted chunks, then finishes.
public struct FakeAudioSource: AudioSource {
    public let chunks: [PCMChunk]
    public let startError: (any Error)?

    public init(chunks: [PCMChunk], startError: (any Error)? = nil) {
        self.chunks = chunks
        self.startError = startError
    }

    public func start() async throws -> AsyncStream<PCMChunk> {
        if let startError { throw startError }
        let chunks = chunks
        return AsyncStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    public func stop() async {}
}
