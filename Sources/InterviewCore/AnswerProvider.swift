import Foundation

/// Who writes the suggested answers. Everything except Anthropic speaks the OpenAI-compatible
/// chat API, so one engine covers all the free options.
public enum AnswerProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case gemini
    case groq
    case openRouter
    case ollama
    case openAI
    case anthropic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gemini: return "Google Gemini"
        case .groq: return "Groq"
        case .openRouter: return "OpenRouter"
        case .ollama: return L10n.tr("Ollama (on this Mac)")
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic Claude"
        }
    }

    public var costNote: String {
        switch self {
        case .gemini: return L10n.tr("free or paid key")
        case .groq: return L10n.tr("free tier")
        case .openRouter: return L10n.tr("free models")
        case .ollama: return L10n.tr("free, offline")
        case .openAI, .anthropic: return L10n.tr("paid")
        }
    }

    public var pickerTitle: String { "\(displayName) · \(costNote)" }

    /// Model used when the user has not typed another one. Free-tier model names change over time,
    /// so the field in Settings stays editable and `fallbackModels` back it up. Google retires models quickly (2.5 is already closed to new users): last checked Nov 2026.
    public var defaultModel: String {
        switch self {
        case .gemini: return "gemini-3.5-flash-lite"
        case .groq: return "llama-3.3-70b-versatile"
        case .openRouter: return "meta-llama/llama-3.3-70b-instruct:free"
        case .ollama: return "llama3.1:8b"
        case .openAI: return "gpt-4o-mini"
        case .anthropic: return AppSettings.defaultModel
        }
    }

    /// Model that can read screenshots, for providers whose default model cannot. nil: the chosen model
    /// is used as is (Gemini, OpenAI and Claude models all accept images). Last checked Nov 2026.
    public var visionModel: String? {
        switch self {
        case .groq: return "qwen/qwen3.8-27b"
        case .openRouter: return "google/gemma-3-27b-it:free"
        case .ollama: return "llama3.2-vision"
        case .gemini, .openAI, .anthropic: return nil
        }
    }

    /// Backup models tried when the chosen one is overloaded or unavailable (free tiers return 503/429 in spikes).
    public var fallbackModels: [String] {
        switch self {
        case .gemini: return ["gemini-3.6-flash", "gemini-flash-latest"]
        case .groq: return ["llama-3.1-8b-instant"]
        case .openRouter, .ollama, .openAI, .anthropic: return []
        }
    }

    /// Base URL of the OpenAI-compatible API; nil for Anthropic's own API.
    public var baseURL: URL? {
        switch self {
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")
        case .groq: return URL(string: "https://api.groq.com/openai/v1")
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1")
        case .ollama: return URL(string: "http://localhost:11434/v1")
        case .openAI: return URL(string: "https://api.openai.com/v1")
        case .anthropic: return nil
        }
    }

    /// Keychain slot for this provider's key; nil when no key is needed (Ollama).
    public var secretKey: SecretKey? {
        switch self {
        case .gemini: return .geminiAPIKey
        case .groq: return .groqAPIKey
        case .openRouter: return .openRouterAPIKey
        case .ollama: return nil
        case .openAI: return .openAIAPIKey
        case .anthropic: return .anthropicAPIKey
        }
    }

    public var needsKey: Bool { secretKey != nil }

    /// Output budget. Gemini's "thinking" models spend part of it on reasoning, so it needs more headroom.
    public var maxTokens: Int {
        switch self {
        case .gemini: return 4_096
        default: return 700
        }
    }

    public var keyHelpURL: URL? {
        switch self {
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .openRouter: return URL(string: "https://openrouter.ai/keys")
        case .ollama: return URL(string: "https://ollama.com/download")
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        }
    }

    public var keyHelpText: String {
        switch self {
        case .gemini: return L10n.tr("Free key (Google account, no card) or a paid key: both come from aistudio.google.com/apikey.")
        case .groq: return L10n.tr("Get a free key at console.groq.com/keys.")
        case .openRouter: return L10n.tr("Get a key at openrouter.ai/keys; models whose name ends in :free cost nothing.")
        case .ollama: return L10n.tr("No key needed. Install Ollama, then run: ollama pull llama3.1:8b")
        case .openAI: return L10n.tr("Paid. Get a key at platform.openai.com/api-keys. The same key also works for speech recognition.")
        case .anthropic: return L10n.tr("Paid. Get a key at console.anthropic.com.")
        }
    }
}

public enum AnswerEngineFactory {
    /// Builds the engine for a provider. Providers with backup models get a `FallbackAnswerEngine`
    /// (primary first); the others a single engine. `vision` builds the engine used for screenshots:
    /// `model` is then the screenshot model, and the output budget is larger because answers carry code.
    public static func make(
        provider: AnswerProvider,
        apiKey: String,
        model: String,
        vision: Bool = false,
        session: URLSession = .shared,
        retryDelay: TimeInterval = 0.6
    ) -> AnswerEngine {
        let name = model.trimmingCharacters(in: .whitespaces)
        let resolved = name.isEmpty ? provider.defaultModel : name
        let maxTokens = vision ? max(provider.maxTokens, 2_048) : provider.maxTokens

        func engine(_ modelName: String) -> AnswerEngine {
            if let baseURL = provider.baseURL {
                return OpenAICompatibleAnswerEngine(
                    baseURL: baseURL, apiKey: apiKey, model: modelName, maxTokens: maxTokens, session: session
                )
            }
            return AnthropicAnswerEngine(apiKey: apiKey, model: modelName, maxTokens: maxTokens, session: session)
        }

        // Backups: the provider's own backups, plus its default model when the user picked another one.
        // A provider with a dedicated screenshot model has no text-model backups: they cannot read images.
        var names = [resolved]
        if !vision || provider.visionModel == nil {
            for candidate in [provider.defaultModel] + provider.fallbackModels where !names.contains(candidate) {
                names.append(candidate)
            }
        }
        guard names.count > 1 else { return engine(resolved) }
        return FallbackAnswerEngine(engines: names.map(engine), names: names, delay: retryDelay)
    }
}
