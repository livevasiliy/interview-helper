import AppKit
import Foundation
import InterviewCore

struct TranscriptLine: Identifiable, Equatable {
    let id = UUID()
    let speaker: Speaker
    var text: String
    var isFinal: Bool
}

/// Builds the real pipeline from the user's settings and Keychain keys, owns the running
/// `SessionController`, and publishes its events as UI state (consumed by the overlay in T12).
@MainActor
final class SessionCoordinator: ObservableObject {
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var lines: [TranscriptLine] = []
    @Published private(set) var question: String?
    @Published private(set) var answer = ""
    @Published private(set) var answerError: String?
    @Published private(set) var isAnswering = false
    @Published private(set) var warnings: [String] = []

    /// Called when a session cannot start because setup is incomplete.
    var onNeedsSetup: (([SetupStep]) -> Void)?

    private let secrets: SecretStore
    private let settingsStore: SettingsStore
    private let permissions: PermissionsService
    private var controller: SessionController?
    private var eventTask: Task<Void, Never>?
    private var resumeAfterWake = false
    private var observers: [NSObjectProtocol] = []

    private let maxLines = 60
    private let maxWarnings = 5

    init(
        secrets: SecretStore = KeychainSecretStore(service: SetupViewModel.keychainService),
        settingsStore: SettingsStore = UserDefaultsSettingsStore(),
        permissions: PermissionsService = SystemPermissionsService()
    ) {
        self.secrets = secrets
        self.settingsStore = settingsStore
        self.permissions = permissions
        observeSleepAndWake()
    }

    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    var content: OverlayContent {
        OverlayContent(state: state, lines: lines, question: question, answer: answer,
                       answerError: answerError, isAnswering: isAnswering, warnings: warnings)
    }

    var isActive: Bool {
        switch state {
        case .starting, .running, .stopping: return true
        case .idle, .failed: return false
        }
    }

    func toggle() {
        switch state {
        case .idle, .failed: start()
        case .starting, .running: stop()
        case .stopping: break
        }
    }

    func start() {
        guard !isActive else { return }

        let settings = settingsStore.load()
        let provider = settings.answerProvider
        let setup = SetupState.current(permissions: permissions, secrets: secrets, provider: provider)
        guard setup.isReady,
              let deepgramKey = (try? secrets.get(.deepgramAPIKey)) ?? nil
        else {
            onNeedsSetup?(setup.missing)
            return
        }
        // Ollama needs no key; for the others `isReady` already guarantees one is saved.
        let answerKey: String = provider.secretKey.map { ((try? secrets.get($0)) ?? nil) ?? "" } ?? ""

        let system = SystemAudioCapture()
        let microphone = MicrophoneCapture(deviceUID: settings.microphoneDeviceUID)
        let controller = SessionController(
            systemAudio: system,
            microphone: microphone,
            transcriber: DeepgramTranscriber(configuration: DeepgramConfiguration(
                apiKey: deepgramKey, language: settings.interviewLanguage.deepgramCode
            )),
            answerEngine: AnswerEngineFactory.make(provider: provider, apiKey: answerKey, model: settings.modelName(for: provider)),
            promptBuilder: settings.promptBuilder,
            answerFromMicrophone: settings.answerMicrophoneQuestions
        )
        system.onUnexpectedStop = { [weak controller] error in
            let reason = error.localizedDescription
            Task { await controller?.sourceStopped(.interviewer, reason: reason) }
        }
        microphone.onUnexpectedStop = { [weak controller] error in
            let reason = error.localizedDescription
            Task { await controller?.sourceStopped(.me, reason: reason) }
        }

        resetOutput()
        self.controller = controller
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in controller.events {
                self?.apply(event)
            }
        }
        Task { await controller.start() }
    }

    /// Answers right away with what the interviewer just said (unfinished speech included).
    func askNow() {
        guard state == .running, let controller else { return }
        Task { await controller.askNow() }
    }

    func stop() {
        guard let controller else { return }
        Task { await controller.stop() }
    }

    // MARK: Events → UI state

    private func resetOutput() {
        lines = []
        question = nil
        answer = ""
        answerError = nil
        isAnswering = false
        warnings = []
    }

    private func apply(_ event: SessionEvent) {
        switch event {
        case .stateChanged(let newState):
            state = newState
        case .transcript(let segment):
            applyTranscript(segment)
        case .question(_, let text):
            question = text
            answer = ""
            answerError = nil
            isAnswering = true
        case .answerDelta(_, let text):
            answer += text
        case .answerFinished:
            isAnswering = false
        case .answerFailed(_, let message):
            answerError = message
            isAnswering = false
        case .warning(let message):
            warnings.append(message)
            if warnings.count > maxWarnings { warnings.removeFirst(warnings.count - maxWarnings) }
        }
    }

    /// An interim line for a speaker is replaced in place until its final version arrives.
    private func applyTranscript(_ segment: TranscriptSegment) {
        if let last = lines.last, last.speaker == segment.speaker, !last.isFinal {
            lines[lines.count - 1].text = segment.text
            lines[lines.count - 1].isFinal = segment.isFinal
        } else {
            lines.append(TranscriptLine(speaker: segment.speaker, text: segment.text, isFinal: segment.isFinal))
        }
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    // MARK: Sleep / wake

    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.resumeAfterWake = true
                self.stop()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.resumeAfterWake else { return }
                self.resumeAfterWake = false
                // Give the network and audio devices a moment to come back.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self?.start()
                }
            }
        })
    }
}
