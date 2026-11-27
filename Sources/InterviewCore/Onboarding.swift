import Foundation

public enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    case notDetermined
}

/// Abstracts macOS permission checks so onboarding logic is testable.
public protocol PermissionsService: Sendable {
    func microphoneStatus() -> PermissionStatus
    func requestMicrophone() async -> Bool
    /// macOS cannot distinguish "denied" from "never asked" for Screen Recording.
    func screenRecordingStatus() -> PermissionStatus
    func requestScreenRecording() -> Bool
}

public struct FakePermissionsService: PermissionsService {
    public var microphone: PermissionStatus
    public var screenRecording: PermissionStatus

    public init(microphone: PermissionStatus = .notDetermined, screenRecording: PermissionStatus = .notDetermined) {
        self.microphone = microphone
        self.screenRecording = screenRecording
    }

    public func microphoneStatus() -> PermissionStatus { microphone }
    public func requestMicrophone() async -> Bool { microphone == .granted }
    public func screenRecordingStatus() -> PermissionStatus { screenRecording }
    public func requestScreenRecording() -> Bool { screenRecording == .granted }
}

public enum SetupStep: CaseIterable, Sendable {
    case microphone
    case screenRecording
    /// The key for the chosen answer provider (not needed for Ollama).
    case answerKey
    case deepgramKey
}

/// What is still needed before a session can start.
public struct SetupState: Equatable, Sendable {
    public var microphone: PermissionStatus
    public var screenRecording: PermissionStatus
    public var answerProvider: AnswerProvider
    /// True when the chosen provider's key is saved, or when it needs none.
    public var hasAnswerKey: Bool
    public var hasDeepgramKey: Bool

    public init(
        microphone: PermissionStatus,
        screenRecording: PermissionStatus,
        answerProvider: AnswerProvider = AppSettings.defaultProvider,
        hasAnswerKey: Bool,
        hasDeepgramKey: Bool
    ) {
        self.microphone = microphone
        self.screenRecording = screenRecording
        self.answerProvider = answerProvider
        self.hasAnswerKey = hasAnswerKey
        self.hasDeepgramKey = hasDeepgramKey
    }

    public static func current(
        permissions: PermissionsService,
        secrets: SecretStore,
        provider: AnswerProvider = AppSettings.defaultProvider
    ) -> SetupState {
        SetupState(
            microphone: permissions.microphoneStatus(),
            screenRecording: permissions.screenRecordingStatus(),
            answerProvider: provider,
            hasAnswerKey: provider.secretKey.map { secrets.has($0) } ?? true,
            hasDeepgramKey: secrets.has(.deepgramAPIKey)
        )
    }

    public func isDone(_ step: SetupStep) -> Bool {
        switch step {
        case .microphone: return microphone == .granted
        case .screenRecording: return screenRecording == .granted
        case .answerKey: return hasAnswerKey
        case .deepgramKey: return hasDeepgramKey
        }
    }

    public var missing: [SetupStep] { SetupStep.allCases.filter { !isDone($0) } }
    public var isReady: Bool { missing.isEmpty }
    public var nextStep: SetupStep? { missing.first }
}
