import Foundation

/// Streaming speech-to-text provider (ADR-002).
public protocol Transcriber: Sendable {
    func transcribe(audio: AsyncStream<PCMChunk>, speaker: Speaker) -> AsyncThrowingStream<TranscriptSegment, Error>
}

public struct PromptMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public struct AnswerPrompt: Sendable, Equatable {
    public let system: String
    public let messages: [PromptMessage]
    /// A screenshot (JPEG) attached to the last user message, for engines that read images.
    public let imageJPEG: Data?

    public init(system: String, messages: [PromptMessage], imageJPEG: Data? = nil) {
        self.system = system
        self.messages = messages
        self.imageJPEG = imageJPEG
    }
}

/// Streaming LLM provider (ADR-002). Yields text deltas.
public protocol AnswerEngine: Sendable {
    func answer(for prompt: AnswerPrompt) -> AsyncThrowingStream<String, Error>
}

/// A live audio source (system output or microphone) producing 16 kHz mono PCM.
public protocol AudioSource: Sendable {
    /// Starts capturing. The stream finishes when `stop()` is called or capture ends.
    func start() async throws -> AsyncStream<PCMChunk>
    func stop() async
}
