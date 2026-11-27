import AppKit
import Carbon.HIToolbox
import Combine
import InterviewCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var statusLine: NSMenuItem?
    private var infoLine: NSMenuItem?
    private var toggleItem: NSMenuItem?
    private var updateItem: NSMenuItem?
    private var window: NSWindow?
    private var hotKeys: [GlobalHotKey] = []
    private var unavailableShortcuts: [Shortcut] = []
    private let appearance = OverlayAppearance()
    private var cancellables = Set<AnyCancellable>()

    private let setupModel = SetupViewModel()
    private let session = SessionCoordinator()
    private let audioProbe = AudioProbe()
    private var overlay: OverlayController?
    private var sessionWasActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // UI tests drive the app like a normal one: a regular app with a Dock presence, no menu bar tricks.
        if UITestMode.isActive { NSApp.setActivationPolicy(.regular) }
        installMainMenu()

        let item = StatusItemFactory.make()
        statusItem = item
        item.button?.toolTip = "Interview Helper"
        setStatusIcon("waveform", fallback: "IH")

        buildStatusMenu(for: item)

        let overlay = OverlayController(session: session, appearance: appearance)
        self.overlay = overlay
        setupModel.$settings
            .map(\.overlayTextSize)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.appearance.textSize = $0 }
            .store(in: &cancellables)
        setupModel.$settings
            .map(\.hideOverlayFromCapture)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { overlay.setHiddenFromCapture($0) }
            .store(in: &cancellables)
        // Switching the interface language redraws the menus and the overlay straight away.
        setupModel.$settings
            .map(\.uiLanguage)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.languageChanged() }
            .store(in: &cancellables)
        // The menu shows what the app is configured to use, and whether setup is still missing something.
        setupModel.$settings
            .combineLatest(setupModel.$state)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings, setup in self?.renderInfo(settings: settings, setup: setup) }
            .store(in: &cancellables)

        setupModel.updates.start { [weak self] in self?.setupModel.settings.checkForUpdates ?? false }
        setupModel.updates.$available
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.renderUpdateItem() }
            .store(in: &cancellables)

        session.onNeedsSetup = { [weak self] missing in
            self?.setupModel.showBlocked(missing: missing)
            self?.showSettings()
        }
        session.$state
            .combineLatest(session.$warnings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, warnings in self?.render(state: state, warnings: warnings) }
            .store(in: &cancellables)

        // Global shortcuts work from any app, including while the interview window has focus.
        for shortcut in Shortcut.allCases where !UITestMode.isActive {
            if let hotKey = GlobalHotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, action: { [weak self] in
                MainActor.assumeIsolated { self?.perform(shortcut) }
            }) {
                hotKeys.append(hotKey)
            } else {
                unavailableShortcuts.append(shortcut)
            }
        }
        overlay.show()
        render(state: session.state, warnings: session.warnings)

        // First run: guide the user through setup.
        if !setupModel.state.isReady || UITestMode.isActive { showSettings() }
        if UITestMode.has("--ui-autostart") { session.start() }

        // A crowded menu bar (notched MacBooks) can hide the icon. Check, and fall back to the Dock.
        if !UITestMode.isActive { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.verifyMenuBarIcon()
        } }
    }

    /// Launching the app again (Finder, Dock, `open`) brings up the window, so it never feels like
    /// "nothing happened" when the menu bar icon is hidden or hard to find.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    // MARK: Menus

    /// Standard app menu. It is invisible while the app only lives in the menu bar, but its key
    /// equivalents work whenever the app is active: ⌘, opens Settings, ⌘Q quits, ⌘V pastes API keys.
    /// (A system-wide ⌘, would hijack Settings in every other app, so the global one is ⌃⌥,.)
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "Interview Helper")
        appMenu.addItem(withTitle: tr("Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Quit Interview Helper"), action: #selector(quitNow), keyEquivalent: "q").target = self
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: tr("Edit"))
        edit.addItem(withTitle: tr("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: tr("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: tr("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        NSApp.mainMenu = main
    }

    /// The menu bar icon's menu. Built from scratch so a language switch can simply rebuild it.
    private func buildStatusMenu(for item: NSStatusItem) {
        let menu = NSMenu()
        let status = NSMenuItem(title: tr("Idle"), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let info = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        let toggle = menu.addItem(withTitle: tr("Start Session    %@", Shortcut.startStop.symbols), action: #selector(toggleSession), keyEquivalent: "")
        toggle.target = self
        menu.addItem(withTitle: tr("Answer Now    %@", Shortcut.answerNow.symbols), action: #selector(answerNow), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("Analyze Screen    %@", Shortcut.analyzeScreen.symbols), action: #selector(analyzeScreen), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("Show/Hide Overlay    %@", Shortcut.toggleOverlay.symbols), action: #selector(toggleOverlay), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        let update = menu.addItem(withTitle: tr("Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        updateItem = update
        renderUpdateItem()
        menu.addItem(.separator())
        menu.addItem(withTitle: "Debug: Test System Audio (5 s)", action: #selector(testSystemAudio), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Debug: Test Microphone (5 s)", action: #selector(testMicrophone), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Quit Interview Helper"), action: #selector(quitNow), keyEquivalent: "q").target = self
        item.menu = menu
        statusLine = status
        infoLine = info
        toggleItem = toggle
    }

    private func languageChanged() {
        appearance.language = L10n.language
        installMainMenu()
        if let item = statusItem { buildStatusMenu(for: item) }
        render(state: session.state, warnings: session.warnings)
        renderInfo(settings: setupModel.settings, setup: setupModel.state)
    }

    private func verifyMenuBarIcon() {
        guard let item = statusItem else { return }
        let result = StatusItemFactory.visibility(of: item)
        guard !result.isVisible else { return }
        // No room for the icon: also show the app in the Dock so it is never unreachable.
        NSApp.setActivationPolicy(.regular)
        setupModel.showMenuBarNote()
        showSettings()
    }

    private func renderInfo(settings: AppSettings, setup: SetupState) {
        var text = "\(settings.answerProvider.displayName) · \(settings.interviewLanguage.displayName)"
        if !setup.isReady { text += tr(" — setup needed") }
        infoLine?.title = text
    }

    private func render(state: SessionState, warnings: [String]) {
        let symbol: String
        let fallback: String
        var line: String
        switch state {
        case .idle: symbol = "waveform"; fallback = "IH"; line = tr("Idle")
        case .starting: symbol = "ellipsis.circle"; fallback = "IH …"; line = tr("Starting…")
        case .running: symbol = "mic.fill"; fallback = "IH ●"; line = tr("Listening")
        case .stopping: symbol = "ellipsis.circle"; fallback = "IH …"; line = tr("Stopping…")
        case .failed(let message): symbol = "exclamationmark.triangle.fill"; fallback = "IH !"; line = tr("Failed: %@", message)
        }
        if let warning = warnings.last { line += " — \(warning)" }
        if !unavailableShortcuts.isEmpty {
            line += tr(" — shortcut taken by another app: %@", unavailableShortcuts.map(\.symbols).joined(separator: ", "))
        }
        setStatusIcon(symbol, fallback: fallback)
        statusItem?.button?.toolTip = "Interview Helper: " + line
        statusLine?.title = line.count > 90 ? String(line.prefix(87)) + "…" : line

        // Starting or stopping a session never touches the overlay: ⌃⌥Space only switches listening
        // on and off. The overlay is shown at launch and hidden only by ⌃⌥O, the × button or the menu.
        let active: Bool
        switch state {
        case .starting, .running, .stopping: active = true
        case .idle, .failed: active = false
        }
        sessionWasActive = active

        switch state {
        case .starting, .running: toggleItem?.title = tr("Stop Session    %@", Shortcut.startStop.symbols)
        default: toggleItem?.title = tr("Start Session    %@", Shortcut.startStop.symbols)
        }
        toggleItem?.isEnabled = state != .stopping
    }

    /// Menu bar icon (template image so it adapts to light/dark); falls back to text if the symbol is missing.
    private func setStatusIcon(_ symbol: String, fallback: String) {
        guard let button = statusItem?.button else { return }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Interview Helper") {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = fallback
        }
    }

    // MARK: Actions

    private func perform(_ shortcut: Shortcut) {
        switch shortcut {
        case .startStop: session.toggle()
        case .answerNow: session.askNow()
        case .analyzeScreen: session.analyzeScreen()
        case .toggleOverlay: overlay?.toggle()
        case .openSettings: showSettings()
        }
    }

    /// "Update to vX…" appears in the menu once a newer release is known; otherwise a manual check.
    private func renderUpdateItem() {
        if let release = setupModel.updates.available {
            updateItem?.title = tr("Update to %@…", release.version.description)
        } else {
            updateItem?.title = tr("Check for Updates…")
        }
    }

    @objc func checkForUpdates() {
        if setupModel.updates.available != nil {
            setupModel.updates.installAvailable()
        } else {
            showSettings()
            setupModel.selectedTab = .settings
            setupModel.updates.checkNow()
        }
    }

    @objc func toggleSession() { session.toggle() }

    @objc func answerNow() { session.askNow() }

    @objc func analyzeScreen() { session.analyzeScreen() }

    @objc func toggleOverlay() { overlay?.toggle() }

    /// Quits immediately; capture streams and sockets end with the process.
    @objc func quitNow() { NSApp.terminate(nil) }

    @objc func testSystemAudio() {
        Task {
            await audioProbe.run(
                source: SystemAudioCapture(),
                title: "System audio test",
                fileName: "interview-helper-system-audio.wav",
                silenceHint: "Is anything playing? Play a video or a call while the test runs, and check the output isn't muted.",
                failureHint: "If this is a permission error: enable Interview Helper in System Settings → Privacy & Security → Screen Recording, then restart the app."
            )
        }
    }

    @objc func testMicrophone() {
        Task {
            await audioProbe.run(
                source: MicrophoneCapture(deviceUID: setupModel.settings.microphoneDeviceUID),
                title: "Microphone test",
                fileName: "interview-helper-microphone.wav",
                silenceHint: "Speak while the test runs, and check the right input device is selected in System Settings → Sound.",
                failureHint: "If this is a permission error: allow Interview Helper in System Settings → Privacy & Security → Microphone (or use Settings…)."
            )
        }
    }

    @objc func showSettings() {
        setupModel.refresh()
        if window == nil {
            let hosting = NSHostingController(rootView: SetupView(model: setupModel))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Interview Helper"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            if UITestMode.isActive, let screen = NSScreen.main {
                w.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.maxY - 20))
            } else {
                w.center()
            }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// Dev tool: `InterviewHelper --render-overlay-preview=/some/dir` writes PNGs of the overlay and exits.
if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--render-overlay-preview=") }) {
    let directory = String(arg.dropFirst("--render-overlay-preview=".count))
    let language: UILanguage = CommandLine.arguments.contains("--language=ru") ? .russian : .english
    MainActor.assumeIsolated { OverlayPreview.render(to: directory, language: language) }
    exit(0)
}

// Dev tool: `InterviewHelper --diagnose-menubar` reports whether macOS actually shows the menu bar icon.
if CommandLine.arguments.contains("--diagnose-menubar") {
    MainActor.assumeIsolated { StatusItemFactory.diagnose() }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
