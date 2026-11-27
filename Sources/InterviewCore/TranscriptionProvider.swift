import Foundation

/// Who turns speech into text. Deepgram streams over a WebSocket; Groq and OpenAI transcribe
/// finished utterances over plain HTTPS (`WhisperTranscriber`), so a Groq or OpenAI key can serve both.
public enum TranscriptionProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case deepgram
    case groq
    case openAI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .deepgram: return "Deepgram"
        case .groq: return "Groq Whisper"
        case .openAI: return "OpenAI"
        }
    }

    public var costNote: String {
        switch self {
        case .deepgram: return L10n.tr("$200 free credit")
        case .groq: return L10n.tr("free tier")
        case .openAI: return L10n.tr("paid")
        }
    }

    public var pickerTitle: String { "\(displayName) · \(costNote)" }

    /// Keychain slot shared with the answer provider of the same name.
    public var secretKey: SecretKey {
        switch self {
        case .deepgram: return .deepgramAPIKey
        case .groq: return .groqAPIKey
        case .openAI: return .openAIAPIKey
        }
    }

    /// Model used when the user has not typed another one. Names change over time: last checked Nov 2026.
    public var defaultModel: String {
        switch self {
        case .deepgram: return "nova-3"
        case .groq: return "whisper-large-v3-turbo"
        case .openAI: return "gpt-4o-mini-transcribe"
        }
    }

    /// Base URL of the OpenAI-style `/audio/transcriptions` API; nil for Deepgram.
    public var whisperBaseURL: URL? {
        switch self {
        case .deepgram: return nil
        case .groq: return URL(string: "https://api.groq.com/openai/v1")
        case .openAI: return URL(string: "https://api.openai.com/v1")
        }
    }

    public var keyHelpText: String {
        switch self {
        case .deepgram: return L10n.tr("Deepgram gives $200 of free credit at sign-up, no card needed. Real-time text while people speak.")
        case .groq: return L10n.tr("Free key at console.groq.com/keys, the same one as for answers. Text appears when a phrase ends, about a second later.")
        case .openAI: return L10n.tr("Paid key from platform.openai.com/api-keys, the same one as for answers. Text appears when a phrase ends.")
        }
    }

    public var keyHelpURL: URL? {
        switch self {
        case .deepgram: return URL(string: "https://console.deepgram.com/signup")
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        }
    }

    /// Builds the transcriber for this provider.
    public func makeTranscriber(apiKey: String, model: String, language: InterviewLanguage) -> Transcriber {
        let name = model.trimmingCharacters(in: .whitespaces)
        let resolved = name.isEmpty ? defaultModel : name
        switch self {
        case .deepgram:
            return DeepgramTranscriber(configuration: DeepgramConfiguration(
                apiKey: apiKey, model: resolved, language: language.deepgramCode
            ))
        case .groq, .openAI:
            return WhisperTranscriber(configuration: WhisperConfiguration(
                baseURL: whisperBaseURL!, apiKey: apiKey, model: resolved, language: language.whisperCode
            ))
        }
    }
}
