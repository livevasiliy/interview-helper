import AppKit
import Foundation
import InterviewCore

/// Looks for a newer release in the background and, on the user's say-so, installs it with the same
/// verified installer script the README offers. Never interrupts: an update is only announced in the
/// menu and in Settings, because the app is used during interviews.
@MainActor
final class UpdateService: ObservableObject {
    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var status = ""
    @Published private(set) var isChecking = false

    /// A new check at most this often, however often the timer fires or the app is relaunched.
    static let interval: TimeInterval = 6 * 3_600
    private static let lastCheckKey = "updates.lastCheck"

    private let checker: UpdateChecker
    private let defaults: UserDefaults
    private var isEnabled: () -> Bool = { true }
    private var timer: Timer?

    let currentVersion: String

    init(checker: UpdateChecker = UpdateChecker(), defaults: UserDefaults = .standard) {
        self.checker = checker
        self.defaults = defaults
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Checks shortly after launch, then re-evaluates every 30 minutes; the 6-hour rule keeps requests rare.
    func start(isEnabled: @escaping () -> Bool) {
        self.isEnabled = isEnabled
        if UITestMode.isActive { Task { await check(manual: false) }; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 1_800, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer?.tolerance = 300
    }

    private func checkIfDue() {
        guard isEnabled() else { return }
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.interval else { return }
        Task { await check(manual: false) }
    }

    /// `manual`: the user asked, so say the outcome, including failures.
    func check(manual: Bool) async {
        guard !isChecking else { return }
        if UITestMode.isActive {
            // No network in UI tests: report a pretend release when asked to, otherwise "up to date".
            if let text = UITestMode.value(of: "--ui-update"), let version = AppVersion(text) {
                available = ReleaseInfo(tag: "v\(version)", version: version,
                                        pageURL: URL(string: "https://example.invalid/release")!, notes: "")
                status = tr("Version %@ is available.", version.description)
            } else if manual {
                status = tr("You have the latest version (%@).", currentVersion)
            }
            return
        }
        isChecking = true
        if manual { status = tr("Checking…") }
        defer { isChecking = false }
        do {
            let release = try await checker.newerRelease(than: currentVersion)
            defaults.set(Date(), forKey: Self.lastCheckKey)
            available = release
            if let release {
                status = tr("Version %@ is available.", release.version.description)
            } else if manual {
                status = tr("You have the latest version (%@).", currentVersion)
            }
        } catch {
            // A background failure (offline, rate limit) stays silent and is retried on the next tick.
            if manual { status = error.localizedDescription }
        }
    }

    func checkNow() { Task { await check(manual: true) } }

    /// Where the app is installed, if somewhere the installer script would replace it.
    private var isInstalledInApplications: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path
        return path == "/Applications" || path == NSHomeDirectory() + "/Applications"
    }

    func installAvailable() {
        guard let release = available else { return }
        guard isInstalledInApplications else {
            // A development build or a copy somewhere else: do not overwrite anything, open the release page.
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        let tag = release.tag
        guard tag.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { return }

        let alert = NSAlert()
        alert.messageText = tr("Install version %@?", release.version.description)
        alert.informativeText = tr("The app downloads the release, checks its SHA-256 checksum, replaces itself in Applications and restarts. A running session will be stopped.")
        alert.addButton(withTitle: tr("Install and restart"))
        alert.addButton(withTitle: tr("Release notes"))
        alert.addButton(withTitle: tr("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: runInstaller(tag: tag)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(release.pageURL)
        default: break
        }
    }

    /// Runs the installer pinned to the release's own tag, detached: it quits this app, copies the new
    /// one over it and opens it. The log helps when something goes wrong.
    private func runInstaller(tag: String) {
        let repo = UpdateChecker.defaultRepository
        let url = "https://raw.githubusercontent.com/\(repo)/\(tag)/scripts/install.sh"
        let log = NSHomeDirectory() + "/Library/Logs/InterviewHelper-update.log"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // Values travel as positional arguments, never spliced into the command text.
        process.arguments = ["-c", "(curl -fsSL \"$1\" | VERSION=\"$2\" bash) > \"$3\" 2>&1 &", "_", url, tag, log]
        do {
            try process.run()
            status = tr("Installing…")
        } catch {
            status = error.localizedDescription
        }
    }
}
