import InterviewCore
import SwiftUI

struct SetupView: View {
    @ObservedObject var model: SetupViewModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            SetupChecklistView(model: model)
                .tabItem { Label("Setup", systemImage: "checklist") }
                .tag(SetupTab.setup)
            SettingsFormView(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(SetupTab.settings)
        }
        .padding(16)
        .frame(width: 540, height: 660)
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
                    Label("Everything is set up.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("Finish these steps before starting a session.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Permissions") {
                row("Microphone", "Transcribes your side of the conversation.",
                    done: model.state.isDone(.microphone),
                    action: model.state.microphone == .denied ? "Open System Settings" : "Allow",
                    perform: model.requestMicrophone)
                row("Screen Recording", "Lets the app hear the interviewer's audio from your calls. No video is recorded.",
                    done: model.state.isDone(.screenRecording),
                    action: "Allow", perform: model.requestScreenRecording)
                if !model.state.isDone(.screenRecording) {
                    HStack {
                        Text("After enabling Screen Recording, restart the app.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart app", action: model.relaunch)
                    }
                }
            }

            Section("Suggested answers: who writes them") {
                Picker("Provider", selection: $model.settings.answerProvider) {
                    ForEach(AnswerProvider.allCases) { Text($0.pickerTitle).tag($0) }
                }
                let provider = model.settings.answerProvider
                HStack(alignment: .firstTextBaseline) {
                    Text(provider.keyHelpText)
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let url = provider.keyHelpURL { Link("Open page", destination: url).font(.footnote) }
                }
                if let secretKey = provider.secretKey {
                    keyRow(provider.displayName, key: secretKey, draft: $model.answerKeyDraft, done: model.state.hasAnswerKey)
                } else {
                    Label("No key needed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }

            Section("Speech recognition (keys are stored in your Keychain)") {
                keyRow("Deepgram", key: .deepgramAPIKey, draft: $model.deepgramDraft, done: model.state.hasDeepgramKey)
                HStack(alignment: .firstTextBaseline) {
                    Text("Deepgram gives $200 of free credit at sign-up, no card needed.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Link("Sign up", destination: URL(string: "https://console.deepgram.com/signup")!).font(.footnote)
                }
                if let error = model.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }

            Section("Keyboard shortcuts (work in any app)") {
                ForEach(Shortcut.allCases, id: \.self) { shortcut in
                    HStack {
                        Text(shortcut.title)
                        Spacer()
                        Text(shortcut.symbols)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
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
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if !done { Button(action, action: perform) }
        }
    }

    private func keyRow(_ title: String, key: SecretKey, draft: Binding<String>, done: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? .green : .secondary)
                Text(title.hasSuffix("API key") ? title : title + " API key")
                Spacer()
                if done { Button("Remove") { model.removeKey(key) } }
            }
            HStack {
                SecureField(done ? "Saved. Paste a new key to replace it" : "Paste API key", text: draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.saveKey(key) }
                Button("Save") { model.saveKey(key) }
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
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

    var body: some View {
        Form {
            Section("Language") {
                Picker("Interview language", selection: $model.settings.interviewLanguage) {
                    ForEach(InterviewLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Sets speech recognition and the language of the suggested answers. Applies the next time you start a session. Auto-detect copes with mixed languages but uses more of your Deepgram credit.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Answers") {
                let provider = model.settings.answerProvider
                LabeledContent("Provider", value: provider.pickerTitle)
                TextField("Model", text: modelBinding(provider), prompt: Text(provider.defaultModel))
                Text("Leave empty to use \(provider.defaultModel). Change the provider on the Setup tab.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Microphone") {
                Picker("Input device", selection: $model.settings.microphoneDeviceUID) {
                    Text("System default" + (model.defaultInputName.map { " (\($0))" } ?? "")).tag("")
                    ForEach(model.inputDevices) { Text($0.name).tag($0.id) }
                    if !model.settings.microphoneDeviceUID.isEmpty,
                       !model.inputDevices.contains(where: { $0.id == model.settings.microphoneDeviceUID }) {
                        Text("Saved device (not connected)").tag(model.settings.microphoneDeviceUID)
                    }
                }
                Text("Applies the next time you start a session. With speakers instead of headphones, the microphone also hears the interviewer.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Also answer questions I say into the microphone", isOn: $model.settings.answerMicrophoneQuestions)
                Text("For testing with your own voice, or when the interviewer is in the room. Off by default: normally only the interviewer's audio is treated as questions.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Your background") {
                Text("Role / company").font(.footnote).foregroundStyle(.secondary)
                TextEditor(text: $model.settings.roleContext)
                    .frame(height: 60)
                Text("Resume").font(.footnote).foregroundStyle(.secondary)
                TextEditor(text: $model.settings.resume)
                    .frame(minHeight: 100)
            }

            Section("Overlay") {
                HStack {
                    Text("Text size")
                    Slider(value: $model.settings.overlayTextSize, in: AppSettings.overlayTextSizeRange, step: 1)
                    Text("\(Int(model.settings.overlayTextSize)) pt")
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
                Toggle("Hide overlay from screen sharing and recordings", isOn: $model.settings.hideOverlayFromCapture)
                Text("Off by default. Best effort only: on recent macOS versions some screen-sharing apps can still capture the overlay. Use this only where it is allowed, and follow the rules of your interview or employer.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
