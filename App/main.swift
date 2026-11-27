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
        installMainMenu()

        let item = StatusItemFactory.make()
        statusItem = item
        item.button?.toolTip = "Interview Helper"
        setStatusIcon("waveform", fallback: "IH")

        let menu = NSMenu()
        let status = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let info = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        let toggle = menu.addItem(withTitle: "Start Session    \(Shortcut.startStop.symbols)", action: #selector(toggleSession), keyEquivalent: "")
        toggle.target = self
        menu.addItem(withTitle: "Answer Now    \(Shortcut.answerNow.symbols)", action: #selector(answerNow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show/Hide Overlay    \(Shortcut.toggleOverlay.symbols)", action: #selector(toggleOverlay), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Debug: Test System Audio (5 s)", action: #selector(testSystemAudio), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Debug: Test Microphone (5 s)", action: #selector(testMicrophone), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Interview Helper", action: #selector(quitNow), keyEquivalent: "q").target = self
        item.menu = menu
        statusLine = status
        infoLine = info
        toggleItem = toggle

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
        // The menu shows what the app is configured to use, and whether setup is still missing something.
        setupModel.$settings
            .combineLatest(setupModel.$state)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings, setup in self?.renderInfo(settings: settings, setup: setup) }
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
        for shortcut in Shortcut.allCases {
            if let hotKey = GlobalHotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, action: { [weak self] in
                MainActor.assumeIsolated { self?.perform(shortcut) }
            }) {
                hotKeys.append(hotKey)
            } else {
                unavailableShortcuts.append(shortcut)
            }
        }
        render(state: session.state, warnings: session.warnings)

        // First run: guide the user through setup.
        if !setupModel.state.isReady { showSettings() }

        // A crowded menu bar (notched MacBooks) can hide the icon. Check, and fall back to the Dock.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.verifyMenuBarIcon()
        }
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
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Interview Helper", action: #selector(quitNow), keyEquivalent: "q").target = self
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        NSApp.mainMenu = main
    }

    private func verifyMenuBarIcon() {
        guard let item = statusItem else { return }
        let result = StatusItemFactory.visibility(of: item)
        guard !result.isVisible else { return }
        // No room for the icon: also show the app in the Dock so it is never unreachable.
        NSApp.setActivationPolicy(.regular)
        setupModel.showMenuBarNote("The menu bar is full, so macOS hides the Interview Helper icon. The app now also shows in the Dock; click it to open this window. Quitting a few menu bar apps (or ⌘-dragging icons away) frees space.")
        showSettings()
    }

    private func renderInfo(settings: AppSettings, setup: SetupState) {
        var text = "\(settings.answerProvider.displayName) · \(settings.interviewLanguage.displayName)"
        if !setup.isReady { text += " — setup needed" }
        infoLine?.title = text
    }

    private func render(state: SessionState, warnings: [String]) {
        let symbol: String
        let fallback: String
        var line: String
        switch state {
        case .idle: symbol = "waveform"; fallback = "IH"; line = "Idle"
        case .starting: symbol = "ellipsis.circle"; fallback = "IH …"; line = "Starting…"
        case .running: symbol = "mic.fill"; fallback = "IH ●"; line = "Listening"
        case .stopping: symbol = "ellipsis.circle"; fallback = "IH …"; line = "Stopping…"
        case .failed(let message): symbol = "exclamationmark.triangle.fill"; fallback = "IH !"; line = "Failed: \(message)"
        }
        if let warning = warnings.last { line += " — \(warning)" }
        if !unavailableShortcuts.isEmpty {
            line += " — shortcut taken by another app: " + unavailableShortcuts.map(\.symbols).joined(separator: ", ")
        }
        setStatusIcon(symbol, fallback: fallback)
        statusItem?.button?.toolTip = "Interview Helper: " + line
        statusLine?.title = line.count > 90 ? String(line.prefix(87)) + "…" : line

        // The overlay appears when a session starts and goes away when it ends.
        let active: Bool
        switch state {
        case .starting, .running, .stopping: active = true
        case .idle, .failed: active = false
        }
        if active && !sessionWasActive { overlay?.show() }
        if !active && sessionWasActive, case .idle = state { overlay?.hide() }
        sessionWasActive = active

        switch state {
        case .starting, .running: toggleItem?.title = "Stop Session    \(Shortcut.startStop.symbols)"
        default: toggleItem?.title = "Start Session    \(Shortcut.startStop.symbols)"
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
        case .toggleOverlay: overlay?.toggle()
        case .openSettings: showSettings()
        }
    }

    @objc func toggleSession() { session.toggle() }

    @objc func answerNow() { session.askNow() }

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
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// Dev tool: `InterviewHelper --render-overlay-preview=/some/dir` writes PNGs of the overlay and exits.
if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--render-overlay-preview=") }) {
    let directory = String(arg.dropFirst("--render-overlay-preview=".count))
    MainActor.assumeIsolated { OverlayPreview.render(to: directory) }
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
