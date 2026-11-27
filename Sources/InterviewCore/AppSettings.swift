import Foundation

/// Language of the interview: drives speech recognition and the language of suggested answers.
public enum InterviewLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto
    case russian
    case english

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
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
    public var interviewLanguage: InterviewLanguage
    /// Exclude the overlay from screen sharing/recording. Off by default.
    public var hideOverlayFromCapture: Bool
    public var resume: String
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
        interviewLanguage: InterviewLanguage = .auto,
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
        self.interviewLanguage = interviewLanguage
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

    public mutating func setModelName(_ name: String, for provider: AnswerProvider) {
        if provider == .anthropic {
            anthropicModel = name
        } else {
            providerModels[provider.rawValue] = name
        }
    }

    // MARK: Codable (tolerant: settings saved by an older version still load)

    private enum CodingKeys: String, CodingKey {
        case answerProvider, anthropicModel, providerModels, interviewLanguage
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
        if let language = try? c.decodeIfPresent(InterviewLanguage.self, forKey: .interviewLanguage) {
            interviewLanguage = language
        } else if let legacy = try? c.decodeIfPresent(String.self, forKey: .language) {
            interviewLanguage = InterviewLanguage.fromLegacy(legacy)
        } else {
            interviewLanguage = d.interviewLanguage
        }
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
        try c.encode(interviewLanguage, forKey: .interviewLanguage)
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
