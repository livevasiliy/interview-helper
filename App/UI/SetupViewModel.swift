import AppKit
import SwiftUI
import Foundation
import InterviewCore

enum SetupTab: Hashable {
    case setup
    case settings
}

@MainActor
final class SetupViewModel: ObservableObject {
    nonisolated static let keychainService = "dev.interviewhelper.app"

    private let permissions: PermissionsService
    private let secrets: SecretStore
    private let settingsStore: SettingsStore

    @Published var settings: AppSettings {
        didSet {
            settingsStore.save(settings)
            if oldValue.uiLanguage != settings.uiLanguage {
                L10n.language = settings.uiLanguage.resolved()
            }
            if oldValue.answerProvider != settings.answerProvider
                || oldValue.transcriptionProvider != settings.transcriptionProvider {
                refresh()   // the required keys depend on the providers
            }
        }
    }
    @Published private(set) var state: SetupState
    @Published private(set) var inputDevices: [AudioInputDevice] = AudioInputDevices.all()
    @Published private(set) var defaultInputName: String? = AudioInputDevices.defaultInputName()
    /// Text typed into a key field, per Keychain slot (providers can share a slot).
    @Published var drafts: [SecretKey: String] = [:]
    /// Slots whose saved key is being replaced: only then is the input field shown for a saved key.
    @Published var replacing: Set<SecretKey> = []
    /// Slots whose key is being checked with the provider right now.
    @Published private(set) var validating: Set<SecretKey> = []
    /// Why a key was not saved (shown in red) and notes about a saved one (shown in orange).
    @Published private(set) var keyErrors: [SecretKey: String] = [:]
    @Published private(set) var keyNotes: [SecretKey: String] = [:]
    private let checkKey: (String, SecretKey) async -> KeyCheck
    @Published var errorMessage: String?
    /// Shown at the top of the Setup tab when the user tried to start a session too early.
    @Published private(set) var notice: String?
    @Published var selectedTab: SetupTab = .setup
    /// Set when macOS has no room for the menu bar icon, so the user knows how to reach the app.
    @Published private(set) var menuBarNote: String?

    let updates = UpdateService()
    private var activationObserver: NSObjectProtocol?

    init(
        permissions: PermissionsService = UITestMode.permissions(),
        secrets: SecretStore = UITestMode.secretStore(),
        settingsStore: SettingsStore = UITestMode.settingsStore(),
        checkKey: @escaping (String, SecretKey) async -> KeyCheck = UITestMode.keyChecker()
    ) {
        self.checkKey = checkKey
        self.permissions = permissions
        self.secrets = secrets
        self.settingsStore = settingsStore
        let loaded = settingsStore.load()
        L10n.language = loaded.uiLanguage.resolved()   // before any view or menu reads a string
        self.settings = loaded
        self.state = SetupState.current(permissions: permissions, secrets: secrets, provider: loaded.answerProvider, transcription: loaded.transcriptionProvider)

        // The user returns from System Settings by re-activating the app.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    func refresh() {
        inputDevices = AudioInputDevices.all()
        defaultInputName = AudioInputDevices.defaultInputName()
        state = SetupState.current(permissions: permissions, secrets: secrets, provider: settings.answerProvider, transcription: settings.transcriptionProvider)
        if state.isReady { notice = nil }
    }

    func showMenuBarNote(_ text: String) { menuBarNote = text }

    /// Called when a session could not start: say exactly what is missing and jump to the checklist.
    func showBlocked(missing: [SetupStep]) {
        let names = missing.map { step -> String in
            switch step {
            case .microphone: return tr("Microphone permission")
            case .screenRecording: return tr("Screen Recording permission")
            case .answerKey: return tr("API key for %@", settings.answerProvider.displayName)
            case .transcriptionKey: return tr("API key for %@", settings.transcriptionProvider.displayName)
            }
        }
        notice = names.isEmpty
            ? tr("The session could not start. Check the keys and permissions below.")
            : tr("Can't start a session yet. Still missing: %@.", names.joined(separator: ", "))
        selectedTab = .setup
    }

    func requestMicrophone() {
        if state.microphone == .denied {
            SystemSettingsPane.microphone.open()
            return
        }
        Task {
            _ = await permissions.requestMicrophone()
            refresh()
        }
    }

    func requestScreenRecording() {
        _ = permissions.requestScreenRecording()
        refresh()
        // macOS shows its own prompt once; afterwards the user must toggle it in System Settings.
        if !state.isDone(.screenRecording) { SystemSettingsPane.screenRecording.open() }
    }

    func draft(_ key: SecretKey) -> Binding<String> {
        Binding(
            get: { self.drafts[key] ?? "" },
            set: { self.drafts[key] = $0; self.keyErrors[key] = nil }
        )
    }

    func hasKey(_ key: SecretKey) -> Bool { (try? secrets.get(key)) ?? nil != nil }

    /// Pastes the clipboard into the key field (also what ⌘V does in the field itself).
    func pasteKey(_ key: SecretKey) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        drafts[key] = text
        keyErrors[key] = nil
    }

    /// Cleans the pasted text, checks its format, asks the provider whether it accepts the key, and only
    /// then saves it. A key the provider rejects is never stored; one that could not be verified is.
    func saveKey(_ key: SecretKey) {
        guard !validating.contains(key) else { return }
        let normalized = KeyValidator.normalize(drafts[key] ?? "")
        keyErrors[key] = nil
        keyNotes[key] = nil
        if let problem = KeyValidator.formatProblem(normalized, for: key) {
            keyErrors[key] = problem
            return
        }
        validating.insert(key)
        Task {
            let result = await checkKey(normalized, key)
            validating.remove(key)
            var note = KeyValidator.formatWarning(normalized, for: key)
            switch result {
            case .rejected(let message):
                keyErrors[key] = message
                return
            case .unverified(let message):
                note = message
            case .valid:
                break
            }
            do {
                try secrets.set(normalized, for: key)
                errorMessage = nil
                drafts[key] = ""
                replacing.remove(key)
                keyNotes[key] = note
            } catch {
                errorMessage = "\(error)"
            }
            refresh()
        }
    }

    func removeKey(_ key: SecretKey) {
        do {
            try secrets.set(nil, for: key)
            errorMessage = nil
            replacing.remove(key)
            keyNotes[key] = nil
            keyErrors[key] = nil
        } catch {
            errorMessage = "\(error)"
        }
        refresh()
    }

    /// Screen Recording grants only apply to a freshly launched process.
    func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
