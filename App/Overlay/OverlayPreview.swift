import AppKit
import InterviewCore
import SwiftUI

/// Renders the overlay with sample data to PNG files (dev tool; no screen-recording permission needed).
@MainActor
enum OverlayPreview {
    static func scenes() -> [(name: String, content: OverlayContent, transcript: Bool, size: CGFloat)] {
        let lines = [
            TranscriptLine(speaker: .interviewer, text: "Thanks for joining. Let's start with your background.", isFinal: true),
            TranscriptLine(speaker: .me, text: "Sure, happy to.", isFinal: true),
            TranscriptLine(speaker: .interviewer, text: "Tell me about a time you had to debug a hard production issue?", isFinal: true),
            TranscriptLine(speaker: .interviewer, text: "And what did you learn from", isFinal: false),
        ]
        let answer = """
        - **Context:** payment service timing out under load, ~2% of checkouts failing
        - **Action:** added tracing, found a lock held across a network call, moved it outside the critical section
        - **Result:** timeouts dropped to near zero; added a load test to CI
        - **Lesson:** measure first, then change one thing at a time
        """
        return [
            ("answer", OverlayContent(state: .running, lines: lines,
                                      question: "Tell me about a time you had to debug a hard production issue?",
                                      answer: answer), false, 20),
            ("streaming", OverlayContent(state: .running, lines: lines,
                                         question: "Why do you want to work here?", answer: "", isAnswering: true), false, 20),
            ("transcript", OverlayContent(state: .running, lines: lines,
                                          question: "Tell me about a time you had to debug a hard production issue?",
                                          answer: answer), true, 20),
            ("big", OverlayContent(state: .running, lines: lines,
                                   question: "Расскажи, что такое транзакция в базе данных?",
                                   answer: "- Группа операций, которая выполняется целиком или не выполняется вовсе\n- Свойства **ACID**: атомарность, согласованность, изолированность, долговечность\n- Пример: перевод денег между счетами"), false, 28),
            ("waiting", OverlayContent(state: .running), false, 20),
            ("idle", OverlayContent(state: .idle), false, 20),
            ("failed", OverlayContent(
                state: .failed("The API key was rejected. Check it in Settings."),
                question: "What is a closure?", answer: "A closure captures…",
                answerError: "Request failed (HTTP 429): slow down",
                warnings: ["Microphone unavailable: Microphone permission is not granted."]), false, 20),
        ]
    }

    static func render(to directory: String, language: UILanguage = .english) {
        L10n.language = language.resolved()
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (scheme, background) in [(ColorScheme.light, Color(white: 0.96)), (.dark, Color(white: 0.16))] {
            for scene in scenes() {
                let view = OverlayView(content: scene.content, textSize: scene.size, showTranscript: scene.transcript)
                    .frame(width: 540, height: 480, alignment: .top)
                    .background(background)
                    .environment(\.colorScheme, scheme)

                // Real AppKit rendering (ImageRenderer skips ScrollView content).
                let hosting = NSHostingView(rootView: view)
                hosting.frame = NSRect(x: 0, y: 0, width: 540, height: 480)
                hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()

                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                let name = "overlay-\(scene.name)-\(scheme == .dark ? "dark" : "light").png"
                try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
            }
        }
        renderSetup(to: directory, language: language)
    }

    /// Renders the Setup window's two tabs with throw-away stores (never touches the real Keychain or settings).
    static func renderSetup(to directory: String, language: UILanguage) {
        for tab in [SetupTab.setup, .settings] {
            for scheme in [ColorScheme.light, .dark] {
                let suite = "preview.\(UUID().uuidString)"
                let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suite)!)
                store.save(AppSettings(uiLanguage: language))   // the model reads the language from its settings
                let model = SetupViewModel(
                    permissions: FakePermissionsService(microphone: .granted, screenRecording: .notDetermined),
                    secrets: InMemorySecretStore(),
                    settingsStore: store
                )
                model.selectedTab = tab
                let view = SetupView(model: model).environment(\.colorScheme, scheme)
                let hosting = NSHostingView(rootView: view)
                hosting.frame = NSRect(x: 0, y: 0, width: 540, height: 660)
                hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                let name = "window-\(tab == .setup ? "setup" : "settings")-\(scheme == .dark ? "dark" : "light").png"
                try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            }
        }
    }
}
