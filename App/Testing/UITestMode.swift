import Foundation
import InterviewCore

/// Test mode for the XCUITest suite: `InterviewHelper --ui-testing [flags]`.
///
/// Nothing real is touched: settings live in a throw-away UserDefaults suite, keys in memory, permissions
/// are fakes, the audio/transcription/answer pipeline is canned, and no global hotkeys are registered.
///
///   --ui-keep-state        keep the settings suite from the previous launch (to test persistence)
///   --ui-seed-keys         start with Gemini and Deepgram keys already saved
///   --ui-permissions=denied  microphone and screen recording not granted
///   --ui-autostart         start a session right after launch
///   --ui-update=9.9.9      pretend a newer release exists
enum UITestMode {
    static let arguments = CommandLine.arguments
    static var isActive: Bool { arguments.contains("--ui-testing") }
    static func has(_ flag: String) -> Bool { arguments.contains(flag) }
    static func value(of name: String) -> String? {
        arguments.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
    }

    private static let suiteName = "dev.interviewhelper.uitest"

    private static let sharedSecrets: InMemorySecretStore = {
        let store = InMemorySecretStore()
        if has("--ui-seed-keys") {
            try? store.set("test-gemini-key", for: .geminiAPIKey)
            try? store.set("test-deepgram-key", for: .deepgramAPIKey)
        }
        return store
    }()

    private static let sharedDefaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: suiteName)!
        if !has("--ui-keep-state") {
            defaults.removePersistentDomain(forName: suiteName)
            // English regardless of the machine's language, so the tests can find labels by text.
            UserDefaultsSettingsStore(defaults: defaults).save(AppSettings(uiLanguage: .english))
        }
        return defaults
    }()

    static func secretStore() -> SecretStore {
        isActive ? sharedSecrets : KeychainSecretStore(service: SetupViewModel.keychainService)
    }

    static func settingsStore() -> SettingsStore {
        isActive ? UserDefaultsSettingsStore(defaults: sharedDefaults) : UserDefaultsSettingsStore()
    }

    static func permissions() -> PermissionsService {
        guard isActive else { return SystemPermissionsService() }
        let status: PermissionStatus = value(of: "--ui-permissions") == "denied" ? .denied : .granted
        return FakePermissionsService(microphone: status, screenRecording: status)
    }

    /// A session wired to canned parts: an interviewer question arrives about a second after start.
    static func makeController(settings: AppSettings) -> SessionController {
        SessionController(
            systemAudio: IdleAudioSource(),
            microphone: nil,
            transcriber: CannedTranscriber(),
            answerEngine: CannedAnswerEngine(),
            visionEngine: CannedAnswerEngine(),
            promptBuilder: settings.promptBuilder
        )
    }

    /// Key checks without a network: a key containing "rejected" is refused, "offline" cannot be verified.
    static func keyChecker() -> (String, SecretKey) async -> KeyCheck {
        guard isActive else { return { key, slot in await KeyValidator().check(key, for: slot) } }
        return { key, _ in
            if key.contains("rejected") { return .rejected(tr("%@ did not accept this key. Check that you copied all of it.", "Test provider")) }
            if key.contains("offline") { return .unverified(tr("Could not reach %@ to verify the key. It was saved; you will see an error when it is used if it is wrong.", "Test provider")) }
            return .valid
        }
    }

    /// A tiny valid JPEG; the canned engine only checks that an image is attached.
    static let screenshot = Data([0xFF, 0xD8, 0xFF, 0xD9])
}

struct IdleAudioSource: AudioSource {
    func start() async throws -> AsyncStream<PCMChunk> { AsyncStream { _ in } }
    func stop() async {}
}

/// Emits one interviewer question shortly after the session starts.
struct CannedTranscriber: Transcriber {
    static let question = "What is dependency injection?"

    func transcribe(audio: AsyncStream<PCMChunk>, speaker: Speaker) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                if speaker == .interviewer {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    continuation.yield(TranscriptSegment(speaker: .interviewer, text: Self.question, isFinal: true, start: 0, end: 2))
                }
                // Stay open like a real stream until the session ends.
                for await _ in audio {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Answers deterministically: screenshots get a code block, questions get an echo.
struct CannedAnswerEngine: AnswerEngine {
    func answer(for prompt: AnswerPrompt) -> AsyncThrowingStream<String, Error> {
        let text: String
        if prompt.imageJPEG != nil {
            text = "Approach: one pass.\n```php\necho 'screen solved';\n```"
        } else {
            let content = prompt.messages.last?.content ?? ""
            let question = content.components(separatedBy: "Current question from the interviewer:\n").last ?? content
            text = "- Canned answer for: \(question.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                for piece in text.split(separator: " ", omittingEmptySubsequences: false) {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    continuation.yield(String(piece) + " ")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
