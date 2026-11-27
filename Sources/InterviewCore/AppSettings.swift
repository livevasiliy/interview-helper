import Foundation

/// Language of the interview: drives speech recognition and the language of suggested answers.
public enum InterviewLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto
    case russian
    case english

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return L10n.tr("Auto-detect")
        case .russian: return "Русский"
        case .english: return "English"
        }
    }

    /// Language named in the prompt; nil means "answer in the language of the question".
    public var answerLanguageName: String? {
        switch self {
        case .auto: return nil
        case .russian: return "Russian"
        case .english: return "English"
        }
    }

    /// ISO 639-1 code for Whisper-style APIs; nil lets the model detect the language.
    public var whisperCode: String? {
        switch self {
        case .auto: return nil
        case .russian: return "ru"
        case .english: return "en"
        }
    }

    /// Deepgram `language` parameter. `multi` auto-detects but costs more than a single language.
    public var deepgramCode: String {
        switch self {
        case .auto: return "multi"
        case .russian: return "ru"
        case .english: return "en"
        }
    }

    /// Maps the free-text language older versions stored.
    static func fromLegacy(_ name: String) -> InterviewLanguage {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "russian", "русский": return .russian
        case "english", "английский": return .english
        default: return .auto
        }
    }
}

/// Non-secret user settings. API keys live in `SecretStore`, never here.
public struct AppSettings: Codable, Equatable, Sendable {
    /// Who writes the suggested answers. New installs start on a free provider.
    public var answerProvider: AnswerProvider
    public var anthropicModel: String
    /// Model overrides for the other providers, keyed by `AnswerProvider.rawValue`.
    public var providerModels: [String: String]
    /// Screenshot-model overrides, keyed by `AnswerProvider.rawValue`.
    public var visionModels: [String: String]
    /// Who turns speech into text.
    public var transcriptionProvider: TranscriptionProvider
    /// Transcription model overrides, keyed by `TranscriptionProvider.rawValue`.
    public var transcriptionModels: [String: String]
    public var interviewLanguage: InterviewLanguage
    /// Language of the app's own windows and menus. Auto follows the system language.
    public var uiLanguage: UILanguage
    /// Exclude the overlay from screen sharing/recording. Off by default.
    public var hideOverlayFromCapture: Bool
    /// "About you": experience and background (the field was a pasted resume in older versions).
    public var resume: String
    /// "What the AI should help with": the interview's topic and the kind of help wanted
    /// (stored under the old `roleContext` name).
    public var roleContext: String
    /// CoreAudio UID of the chosen microphone. Empty = follow the system default input.
    public var microphoneDeviceUID: String
    /// Also look for questions in what the user says into the microphone (testing, or an in-room interviewer).
    public var answerMicrophoneQuestions: Bool
    /// Base font size of the overlay's answer text, in points. Everything else scales from it.
    public var overlayTextSize: Double

    public static let overlayTextSizeRange: ClosedRange<Double> = 14...32
    public static let defaultOverlayTextSize: Double = 20
    public static let defaultModel = "claude-sonnet-5-5"
    public static let defaultProvider: AnswerProvider = .gemini

    public init(
        answerProvider: AnswerProvider = AppSettings.defaultProvider,
        anthropicModel: String = AppSettings.defaultModel,
        providerModels: [String: String] = [:],
        visionModels: [String: String] = [:],
        transcriptionProvider: TranscriptionProvider = .deepgram,
        transcriptionModels: [String: String] = [:],
        interviewLanguage: InterviewLanguage = .auto,
        uiLanguage: UILanguage = .auto,
        hideOverlayFromCapture: Bool = false,
        resume: String = "",
        roleContext: String = "",
        microphoneDeviceUID: String = "",
        answerMicrophoneQuestions: Bool = false,
        overlayTextSize: Double = AppSettings.defaultOverlayTextSize
    ) {
        self.answerProvider = answerProvider
        self.anthropicModel = anthropicModel
        self.providerModels = providerModels
        self.visionModels = visionModels
        self.transcriptionProvider = transcriptionProvider
        self.transcriptionModels = transcriptionModels
        self.interviewLanguage = interviewLanguage
        self.uiLanguage = uiLanguage
        self.hideOverlayFromCapture = hideOverlayFromCapture
        self.resume = resume
        self.roleContext = roleContext
        self.microphoneDeviceUID = microphoneDeviceUID
        self.answerMicrophoneQuestions = answerMicrophoneQuestions
        self.overlayTextSize = Self.clampTextSize(overlayTextSize)
    }

    static func clampTextSize(_ value: Double) -> Double {
        min(max(value, overlayTextSizeRange.lowerBound), overlayTextSizeRange.upperBound)
    }

    /// Answer language name for prompts; empty means "same language as the question".
    public var language: String { interviewLanguage.answerLanguageName ?? "" }

    /// The model to call for a provider: the user's override, else the provider's default.
    public func modelName(for provider: AnswerProvider) -> String {
        let chosen = provider == .anthropic ? anthropicModel : providerModels[provider.rawValue]
        let trimmed = chosen?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? provider.defaultModel : trimmed
    }

    /// The model that reads screenshots: the user's override, else the provider's vision model,
    /// else the model used for text answers.
    public func visionModelName(for provider: AnswerProvider) -> String {
        let chosen = visionModels[provider.rawValue]?.trimmingCharacters(in: .whitespaces) ?? ""
        if !chosen.isEmpty { return chosen }
        return provider.visionModel ?? modelName(for: provider)
    }

    public mutating func setVisionModelName(_ name: String, for provider: AnswerProvider) {
        visionModels[provider.rawValue] = name
    }

    /// The speech-to-text model: the user's override, else the provider's default.
    public func transcriptionModelName(for provider: TranscriptionProvider) -> String {
        let chosen = transcriptionModels[provider.rawValue]?.trimmingCharacters(in: .whitespaces) ?? ""
        return chosen.isEmpty ? provider.defaultModel : chosen
    }

    public mutating func setTranscriptionModelName(_ name: String, for provider: TranscriptionProvider) {
        transcriptionModels[provider.rawValue] = name
    }

    public mutating func setModelName(_ name: String, for provider: AnswerProvider) {
        if provider == .anthropic {
            anthropicModel = name
        } else {
            providerModels[provider.rawValue] = name
        }
    }

    // MARK: Codable (tolerant: settings saved by an older version still load)

    private enum CodingKeys: String, CodingKey {
        case answerProvider, anthropicModel, providerModels, visionModels
        case transcriptionProvider, transcriptionModels
        case interviewLanguage, uiLanguage
        case language   // legacy free-text answer language, read only
        case hideOverlayFromCapture, resume, roleContext
        case microphoneDeviceUID, answerMicrophoneQuestions, overlayTextSize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        answerProvider = (try? c.decodeIfPresent(AnswerProvider.self, forKey: .answerProvider)) ?? d.answerProvider
        anthropicModel = try c.decodeIfPresent(String.self, forKey: .anthropicModel) ?? d.anthropicModel
        providerModels = try c.decodeIfPresent([String: String].self, forKey: .providerModels) ?? d.providerModels
        visionModels = try c.decodeIfPresent([String: String].self, forKey: .visionModels) ?? d.visionModels
        transcriptionProvider = (try? c.decodeIfPresent(TranscriptionProvider.self, forKey: .transcriptionProvider)) ?? d.transcriptionProvider
        transcriptionModels = try c.decodeIfPresent([String: String].self, forKey: .transcriptionModels) ?? d.transcriptionModels
        if let language = try? c.decodeIfPresent(InterviewLanguage.self, forKey: .interviewLanguage) {
            interviewLanguage = language
        } else if let legacy = try? c.decodeIfPresent(String.self, forKey: .language) {
            interviewLanguage = InterviewLanguage.fromLegacy(legacy)
        } else {
            interviewLanguage = d.interviewLanguage
        }
        uiLanguage = (try? c.decodeIfPresent(UILanguage.self, forKey: .uiLanguage)) ?? d.uiLanguage
        hideOverlayFromCapture = try c.decodeIfPresent(Bool.self, forKey: .hideOverlayFromCapture) ?? d.hideOverlayFromCapture
        resume = try c.decodeIfPresent(String.self, forKey: .resume) ?? d.resume
        roleContext = try c.decodeIfPresent(String.self, forKey: .roleContext) ?? d.roleContext
        microphoneDeviceUID = try c.decodeIfPresent(String.self, forKey: .microphoneDeviceUID) ?? d.microphoneDeviceUID
        answerMicrophoneQuestions = try c.decodeIfPresent(Bool.self, forKey: .answerMicrophoneQuestions) ?? d.answerMicrophoneQuestions
        overlayTextSize = Self.clampTextSize(try c.decodeIfPresent(Double.self, forKey: .overlayTextSize) ?? d.overlayTextSize)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(answerProvider, forKey: .answerProvider)
        try c.encode(anthropicModel, forKey: .anthropicModel)
        try c.encode(providerModels, forKey: .providerModels)
        try c.encode(visionModels, forKey: .visionModels)
        try c.encode(transcriptionProvider, forKey: .transcriptionProvider)
        try c.encode(transcriptionModels, forKey: .transcriptionModels)
        try c.encode(interviewLanguage, forKey: .interviewLanguage)
        try c.encode(uiLanguage, forKey: .uiLanguage)
        try c.encode(hideOverlayFromCapture, forKey: .hideOverlayFromCapture)
        try c.encode(resume, forKey: .resume)
        try c.encode(roleContext, forKey: .roleContext)
        try c.encode(microphoneDeviceUID, forKey: .microphoneDeviceUID)
        try c.encode(answerMicrophoneQuestions, forKey: .answerMicrophoneQuestions)
        try c.encode(overlayTextSize, forKey: .overlayTextSize)
    }

    /// Prompt builder configured from these settings.
    public var promptBuilder: PromptBuilder {
        PromptBuilder(resume: resume, roleContext: roleContext, language: interviewLanguage.answerLanguageName)
    }
}

public protocol SettingsStore: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

public struct UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "appSettings.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
