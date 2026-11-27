import InterviewCore
import SwiftUI

struct SetupView: View {
    @ObservedObject var model: SetupViewModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            // .id(language): a tab that is not on screen keeps its old rendering, so each tab is rebuilt
            // when the interface language changes.
            SetupChecklistView(model: model)
                .id(model.settings.uiLanguage)
                .tabItem { Label(tr("Setup"), systemImage: "checklist") }
                .tag(SetupTab.setup)
            SettingsFormView(model: model)
                .id(model.settings.uiLanguage)
                .tabItem { Label(tr("Settings"), systemImage: "gearshape") }
                .tag(SetupTab.settings)
        }
        .padding(16)
        // UI tests get a tall window so every field is on screen and they never depend on scrolling.
        .frame(width: 540, height: UITestMode.isActive ? 1_000 : 660)
    }
}

private struct SetupChecklistView: View {
    @ObservedObject var model: SetupViewModel

    var body: some View {
        Form {
            if let note = model.menuBarNote {
                Section {
                    Label(note, systemImage: "menubar.rectangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let notice = model.notice {
                Section {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                if model.state.isReady {
                    Label(tr("Everything is set up."), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("setup-ready")
                } else {
                    Text(tr("Finish these steps before starting a session."))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("setup-incomplete")
                }
            }

            Section(tr("Permissions")) {
                row(tr("Microphone"), tr("Transcribes your side of the conversation."),
                    done: model.state.isDone(.microphone),
                    action: model.state.microphone == .denied ? tr("Open System Settings") : tr("Allow"),
                    perform: model.requestMicrophone)
                row(tr("Screen Recording"), tr("Lets the app hear the interviewer's audio from your calls. No video is recorded."),
                    done: model.state.isDone(.screenRecording),
                    action: tr("Allow"), perform: model.requestScreenRecording)
                if !model.state.isDone(.screenRecording) {
                    HStack {
                        Text(tr("After enabling Screen Recording, restart the app."))
                            .font(Typography.helper).foregroundStyle(.secondary)
                        Spacer()
                        Button(tr("Restart app"), action: model.relaunch)
                    }
                }
            }

            Section(tr("Suggested answers: who writes them")) {
                Picker(tr("Provider"), selection: $model.settings.answerProvider) {
                    ForEach(AnswerProvider.allCases) { Text($0.pickerTitle).tag($0) }
                }
                .accessibilityIdentifier("answer-provider")
                let provider = model.settings.answerProvider
                helpRow(provider.keyHelpText, url: provider.keyHelpURL)
                if let secretKey = provider.secretKey {
                    keyRow(provider.displayName, key: secretKey)
                } else {
                    Label(tr("No key needed"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }

            Section(tr("Speech recognition (keys are stored in your Keychain)")) {
                Picker(tr("Provider"), selection: $model.settings.transcriptionProvider) {
                    ForEach(TranscriptionProvider.allCases) { Text($0.pickerTitle).tag($0) }
                }
                .accessibilityIdentifier("stt-provider")
                let stt = model.settings.transcriptionProvider
                helpRow(stt.keyHelpText, url: stt.keyHelpURL)
                keyRow(stt.displayName, key: stt.secretKey)
                if let error = model.errorMessage {
                    Text(error).font(Typography.notice).foregroundStyle(.red)
                }
            }

            Section(tr("Keyboard shortcuts (work in any app)")) {
                ForEach(Shortcut.allCases, id: \.self) { shortcut in
                    HStack {
                        Text(shortcut.title)
                        Spacer()
                        Text(shortcut.symbols)
                            .font(Typography.shortcutKey)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ title: String, _ detail: String, done: Bool, action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(Typography.helper).foregroundStyle(.secondary)
            }
            Spacer()
            if !done { Button(action, action: perform) }
        }
    }

    private func helpRow(_ text: String, url: URL?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(Typography.helper).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let url { Link(tr("Open page"), destination: url).font(Typography.helper) }
        }
    }

    /// A saved key collapses to one line (Replace / Remove); the input field only appears when there is
    /// no key yet or the user chose to replace it.
    private func keyRow(_ title: String, key: SecretKey) -> some View {
        let saved = model.hasKey(key)
        let editing = !saved || model.replacing.contains(key)
        let draft = model.draft(key)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: saved ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(saved ? .green : .secondary)
                Text(saved ? tr("%@ API key saved", title) : tr("%@ API key", title))
                    .accessibilityIdentifier("key-status-\(key.rawValue)")
                Spacer()
                if saved && !editing {
                    Button(tr("Replace")) { model.replacing.insert(key) }
                        .accessibilityIdentifier("key-replace-\(key.rawValue)")
                }
                if saved {
                    Button(tr("Remove")) { model.removeKey(key) }
                        .accessibilityIdentifier("key-remove-\(key.rawValue)")
                }
            }
            if editing {
                HStack {
                    PasteableSecureField(placeholder: tr("Paste API key"), text: draft,
                                         onSubmit: { model.saveKey(key) }, identifier: "key-field-\(key.rawValue)")
                        .frame(height: 22)
                    Button(tr("Paste")) { model.pasteKey(key) }
                        .accessibilityIdentifier("key-paste-\(key.rawValue)")
                    if model.validating.contains(key) {
                        ProgressView().controlSize(.small)
                    }
                    Button(tr("Save")) { model.saveKey(key) }
                        .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty || model.validating.contains(key))
                        .accessibilityIdentifier("key-save-\(key.rawValue)")
                    if saved {
                        Button(tr("Cancel")) { model.replacing.remove(key); model.drafts[key] = "" }
                            .accessibilityIdentifier("key-cancel-\(key.rawValue)")
                    }
                }
            }
            if let error = model.keyErrors[key] {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(Typography.notice).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("key-message-\(key.rawValue)")
            } else if let note = model.keyNotes[key] {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.notice).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("key-message-\(key.rawValue)")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SettingsFormView: View {
    @ObservedObject var model: SetupViewModel

    /// Raw stored model name for the chosen provider; empty means "use the default" (shown as the placeholder).
    private func modelBinding(_ provider: AnswerProvider) -> Binding<String> {
        Binding(
            get: { provider == .anthropic ? model.settings.anthropicModel : (model.settings.providerModels[provider.rawValue] ?? "") },
            set: { model.settings.setModelName($0, for: provider) }
        )
    }

    private func visionBinding(_ provider: AnswerProvider) -> Binding<String> {
        Binding(
            get: { model.settings.visionModels[provider.rawValue] ?? "" },
            set: { model.settings.setVisionModelName($0, for: provider) }
        )
    }

    private func sttBinding(_ provider: TranscriptionProvider) -> Binding<String> {
        Binding(
            get: { model.settings.transcriptionModels[provider.rawValue] ?? "" },
            set: { model.settings.setTranscriptionModelName($0, for: provider) }
        )
    }

    var body: some View {
        Form {
            Section(tr("Language")) {
                Picker(tr("Interface language"), selection: $model.settings.uiLanguage) {
                    ForEach(UILanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .accessibilityIdentifier("ui-language")
                Picker(tr("Interview language"), selection: $model.settings.interviewLanguage) {
                    ForEach(InterviewLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(tr("Sets speech recognition and the language of the suggested answers. Applies the next time you start a session. Auto-detect copes with mixed languages but costs more with some providers (Deepgram uses more of your credit)."))
                    .font(Typography.helper).foregroundStyle(.secondary)
            }

            Section(tr("Models")) {
                let provider = model.settings.answerProvider
                LabeledContent(tr("Answers"), value: provider.pickerTitle)
                TextField(tr("Model"), text: modelBinding(provider), prompt: Text(provider.defaultModel))
                TextField(tr("Screenshot model"), text: visionBinding(provider), prompt: Text(model.settings.visionModelName(for: provider)))
                Text(tr("Leave empty to use the suggested model. A paid key works the same way: just save it on the Setup tab and, if you like, type a stronger model here. Change the provider on the Setup tab."))
                    .font(Typography.helper).foregroundStyle(.secondary)
                let stt = model.settings.transcriptionProvider
                TextField(tr("Speech model (%@)", stt.displayName), text: sttBinding(stt), prompt: Text(stt.defaultModel))
            }

            Section(tr("Microphone")) {
                Picker(tr("Input device"), selection: $model.settings.microphoneDeviceUID) {
                    Text(tr("System default") + (model.defaultInputName.map { " (\($0))" } ?? "")).tag("")
                    ForEach(model.inputDevices) { Text($0.name).tag($0.id) }
                    if !model.settings.microphoneDeviceUID.isEmpty,
                       !model.inputDevices.contains(where: { $0.id == model.settings.microphoneDeviceUID }) {
                        Text(tr("Saved device (not connected)")).tag(model.settings.microphoneDeviceUID)
                    }
                }
                Text(tr("Applies the next time you start a session. With speakers instead of headphones, the microphone also hears the interviewer."))
                    .font(Typography.helper).foregroundStyle(.secondary)
                Toggle(tr("Also answer questions I say into the microphone"), isOn: $model.settings.answerMicrophoneQuestions)
                Text(tr("For testing with your own voice, or when the interviewer is in the room. Off by default: normally only the interviewer's audio is treated as questions."))
                    .font(Typography.helper).foregroundStyle(.secondary)
            }

            Section(tr("About you")) {
                Text(tr("About you and your experience")).font(Typography.helper).foregroundStyle(.secondary)
                NoteEditor(text: $model.settings.resume, placeholder: tr("Role, years of experience, stack, projects"), height: 96, id: "about-you")
                Text(tr("What the AI should help with")).font(Typography.helper).foregroundStyle(.secondary)
                NoteEditor(text: $model.settings.roleContext, placeholder: tr("PHP and React.js interview"), height: 70, id: "ai-help")
                Text(tr("For example: PHP and React.js interview. Help me answer questions about PHP and React.js."))
                    .font(Typography.helper).foregroundStyle(.secondary)
            }

            UpdatesSection(updates: model.updates, enabled: $model.settings.checkForUpdates, language: model.settings.uiLanguage)
                .id(model.settings.uiLanguage)

            Section(tr("Overlay")) {
                HStack {
                    Text(tr("Text size"))
                    Slider(value: $model.settings.overlayTextSize, in: AppSettings.overlayTextSizeRange, step: 1)
                    Text(tr("%ld pt", Int(model.settings.overlayTextSize)))
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                Toggle(tr("Hide overlay from screen sharing and recordings"), isOn: $model.settings.hideOverlayFromCapture)
                Text(tr("Off by default. Best effort only: on recent macOS versions some screen-sharing apps can still capture the overlay. Use this only where it is allowed, and follow the rules of your interview or employer."))
                    .font(Typography.helper).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}


/// A multi-line text field that looks like part of the form: rounded, padded, with a placeholder.
private struct NoteEditor: View {
    @Binding var text: String
    let placeholder: String
    let height: CGFloat
    let id: String

    var body: some View {
        TextEditor(text: $text)
            .accessibilityIdentifier(id)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: height)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator) }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}


private struct UpdatesSection: View {
    @ObservedObject var updates: UpdateService
    @Binding var enabled: Bool
    /// Not read, but passed in so this section is redrawn (and re-translated) when the language changes.
    let language: UILanguage

    var body: some View {
        Section(tr("Updates")) {
            LabeledContent(tr("Version"), value: updates.currentVersion)
            Toggle(tr("Check for updates automatically"), isOn: $enabled)
                .accessibilityIdentifier("updates-auto")
            HStack {
                if updates.status != .idle {
                    Text(updates.status.text).font(Typography.helper).foregroundStyle(.secondary)
                        .accessibilityIdentifier("updates-status")
                }
                Spacer()
                Button(tr("Check now")) { updates.checkNow() }.disabled(updates.isChecking)
                    .accessibilityIdentifier("updates-check")
                if updates.available != nil {
                    Button(tr("Update")) { updates.installAvailable() }.prominentGlassButtonStyle()
                        .accessibilityIdentifier("updates-install")
                }
            }
            Text(tr("Once every few hours the app asks GitHub for the latest release. Nothing about you is sent, and updates are never installed without your confirmation."))
                .font(Typography.helper).foregroundStyle(.secondary)
        }
    }
}
