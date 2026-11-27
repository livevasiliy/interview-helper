import AppKit
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
            if oldValue.answerProvider != settings.answerProvider {
                answerKeyDraft = ""
                refresh()   // the required key depends on the provider
            }
        }
    }
    @Published private(set) var state: SetupState
    @Published private(set) var inputDevices: [AudioInputDevice] = AudioInputDevices.all()
    @Published private(set) var defaultInputName: String? = AudioInputDevices.defaultInputName()
    @Published var answerKeyDraft = ""
    @Published var deepgramDraft = ""
    @Published var errorMessage: String?
    /// Shown at the top of the Setup tab when the user tried to start a session too early.
    @Published private(set) var notice: String?
    @Published var selectedTab: SetupTab = .setup
    /// Set when macOS has no room for the menu bar icon, so the user knows how to reach the app.
    @Published private(set) var menuBarNote: String?

    private var activationObserver: NSObjectProtocol?

    init(
        permissions: PermissionsService = SystemPermissionsService(),
        secrets: SecretStore = KeychainSecretStore(service: SetupViewModel.keychainService),
        settingsStore: SettingsStore = UserDefaultsSettingsStore()
    ) {
        self.permissions = permissions
        self.secrets = secrets
        self.settingsStore = settingsStore
        let loaded = settingsStore.load()
        self.settings = loaded
        self.state = SetupState.current(permissions: permissions, secrets: secrets, provider: loaded.answerProvider)

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
        state = SetupState.current(permissions: permissions, secrets: secrets, provider: settings.answerProvider)
        if state.isReady { notice = nil }
    }

    func showMenuBarNote(_ text: String) { menuBarNote = text }

    /// Called when a session could not start: say exactly what is missing and jump to the checklist.
    func showBlocked(missing: [SetupStep]) {
        let names = missing.map { step -> String in
            switch step {
            case .microphone: return "Microphone permission"
            case .screenRecording: return "Screen Recording permission"
            case .answerKey: return "\(settings.answerProvider.displayName) API key"
            case .deepgramKey: return "Deepgram API key"
            }
        }
        notice = names.isEmpty
            ? "The session could not start. Check the keys and permissions below."
            : "Can't start a session yet. Still missing: " + names.joined(separator: ", ") + "."
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

    func saveKey(_ key: SecretKey) {
        let draft = key == .deepgramAPIKey ? deepgramDraft : answerKeyDraft
        do {
            try secrets.set(draft, for: key)
            errorMessage = nil
            if key == .deepgramAPIKey { deepgramDraft = "" } else { answerKeyDraft = "" }
        } catch {
            errorMessage = "\(error)"
        }
        refresh()
    }

    func removeKey(_ key: SecretKey) {
        do {
            try secrets.set(nil, for: key)
            errorMessage = nil
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
