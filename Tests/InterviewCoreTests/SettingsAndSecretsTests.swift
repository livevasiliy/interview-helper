import XCTest
@testable import InterviewCore

final class SecretStoreTests: XCTestCase {
    func testInMemoryTrimsAndDeletesOnBlank() throws {
        let s = InMemorySecretStore()
        try s.set("  sk-123 \n", for: .anthropicAPIKey)
        XCTAssertEqual(try s.get(.anthropicAPIKey), "sk-123")
        XCTAssertTrue(s.has(.anthropicAPIKey))
        try s.set("   ", for: .anthropicAPIKey)
        XCTAssertNil(try s.get(.anthropicAPIKey))
        XCTAssertFalse(s.has(.anthropicAPIKey))
    }

    func testKeysAreIndependent() throws {
        let s = InMemorySecretStore()
        try s.set("a", for: .anthropicAPIKey)
        XCTAssertFalse(s.has(.deepgramAPIKey))
    }

    func testKeychainRoundTrip() throws {
        let store = KeychainSecretStore(service: "dev.interviewhelper.tests.\(UUID().uuidString)")
        addTeardownBlock { for k in SecretKey.allCases { try? store.set(nil, for: k) } }

        XCTAssertNil(try store.get(.anthropicAPIKey))
        try store.set("first", for: .anthropicAPIKey)
        XCTAssertEqual(try store.get(.anthropicAPIKey), "first")
        try store.set("second", for: .anthropicAPIKey)
        XCTAssertEqual(try store.get(.anthropicAPIKey), "second", "update must overwrite")
        XCTAssertNil(try store.get(.deepgramAPIKey))
        try store.set(nil, for: .anthropicAPIKey)
        XCTAssertNil(try store.get(.anthropicAPIKey))
        XCTAssertNoThrow(try store.set(nil, for: .anthropicAPIKey), "deleting a missing item is fine")
    }
}

final class AppSettingsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testDefaults() {
        let s = AppSettings()
        XCTAssertFalse(s.hideOverlayFromCapture, "hiding from capture must be opt-in")
        XCTAssertEqual(s.anthropicModel, AppSettings.defaultModel)
    }

    func testRoundTrip() {
        let store = UserDefaultsSettingsStore(defaults: freshDefaults())
        XCTAssertEqual(store.load(), AppSettings())
        let custom = AppSettings(anthropicModel: "m", interviewLanguage: .russian, hideOverlayFromCapture: true, resume: "r", roleContext: "c")
        store.save(custom)
        XCTAssertEqual(store.load(), custom)
    }

    func testDecodesOlderPayloadWithMissingFields() throws {
        let json = #"{"language":"Russian"}"#.data(using: .utf8)!   // what v1 stored
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(s.interviewLanguage, .russian)
        XCTAssertEqual(s.language, "Russian")
        XCTAssertEqual(s.anthropicModel, AppSettings.defaultModel)
        XCTAssertFalse(s.hideOverlayFromCapture)
    }

    func testCorruptDataFallsBackToDefaults() {
        let d = freshDefaults()
        d.set(Data("not json".utf8), forKey: "appSettings.v1")
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: d).load(), AppSettings())
    }

    func testPromptBuilderUsesLanguageOnlyWhenSet() {
        XCTAssertNil(AppSettings(interviewLanguage: .auto).promptBuilder.language)
        XCTAssertEqual(AppSettings(interviewLanguage: .russian).promptBuilder.language, "Russian")
        XCTAssertEqual(AppSettings(interviewLanguage: .english).promptBuilder.language, "English")
    }
}

final class SetupStateTests: XCTestCase {
    func testNothingDoneListsAllStepsInOrder() {
        let state = SetupState.current(permissions: FakePermissionsService(), secrets: InMemorySecretStore())
        XCTAssertEqual(state.missing, [.microphone, .screenRecording, .answerKey, .transcriptionKey])
        XCTAssertEqual(state.nextStep, .microphone)
        XCTAssertFalse(state.isReady)
    }

    func testReadyWhenEverythingPresent() throws {
        let secrets = InMemorySecretStore()
        try secrets.set("g", for: .geminiAPIKey)   // the default provider is Gemini
        try secrets.set("d", for: .deepgramAPIKey)
        let state = SetupState.current(
            permissions: FakePermissionsService(microphone: .granted, screenRecording: .granted),
            secrets: secrets
        )
        XCTAssertTrue(state.isReady)
        XCTAssertNil(state.nextStep)
    }

    func testDeniedMicrophoneStillCountsAsMissing() {
        let state = SetupState(microphone: .denied, screenRecording: .granted, hasAnswerKey: true, hasTranscriptionKey: true)
        XCTAssertEqual(state.missing, [.microphone])
    }
}

final class MicrophoneSettingTests: XCTestCase {
    func testDefaultsToSystemDefaultInput() {
        XCTAssertEqual(AppSettings().microphoneDeviceUID, "")
    }

    func testRoundTripAndOlderPayload() throws {
        let data = try JSONEncoder().encode(AppSettings(microphoneDeviceUID: "uid-123"))
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).microphoneDeviceUID, "uid-123")
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"language":"German"}"#.utf8))
        XCTAssertEqual(old.microphoneDeviceUID, "")
    }
}

final class AnswerMicrophoneSettingTests: XCTestCase {
    func testOffByDefaultAndSurvivesRoundTrip() throws {
        XCTAssertFalse(AppSettings().answerMicrophoneQuestions)
        let data = try JSONEncoder().encode(AppSettings(answerMicrophoneQuestions: true))
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: data).answerMicrophoneQuestions)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"language":"German"}"#.utf8))
        XCTAssertFalse(old.answerMicrophoneQuestions)
    }
}

final class OverlayTextSizeSettingTests: XCTestCase {
    func testDefaultRoundTripAndClamping() throws {
        XCTAssertEqual(AppSettings().overlayTextSize, AppSettings.defaultOverlayTextSize)
        XCTAssertEqual(AppSettings(overlayTextSize: 100).overlayTextSize, 32)
        XCTAssertEqual(AppSettings(overlayTextSize: 1).overlayTextSize, 14)
        let data = try JSONEncoder().encode(AppSettings(overlayTextSize: 26))
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).overlayTextSize, 26)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"language":"German"}"#.utf8))
        XCTAssertEqual(old.overlayTextSize, AppSettings.defaultOverlayTextSize)
        let wild = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"overlayTextSize":999}"#.utf8))
        XCTAssertEqual(wild.overlayTextSize, 32, "a hand-edited value must not break the layout")
    }
}

final class AudioInputDevicesTests: XCTestCase {
    func testEnumerationIsConsistent() {
        let devices = AudioInputDevices.all()
        // Headless machines may have none; whatever is listed must be well-formed and resolvable.
        for device in devices {
            XCTAssertFalse(device.id.isEmpty)
            XCTAssertFalse(device.name.isEmpty)
            XCTAssertNotNil(AudioInputDevices.deviceID(forUID: device.id), "\(device.name) must resolve from its UID")
        }
        XCTAssertEqual(Set(devices.map(\.id)).count, devices.count, "UIDs must be unique")
        if !devices.isEmpty {
            print("INPUT DEVICES:", devices.map(\.name), "default:", AudioInputDevices.defaultInputName() ?? "none")
        }
    }

    func testUnknownUIDDoesNotResolve() {
        XCTAssertNil(AudioInputDevices.deviceID(forUID: "definitely-not-a-device-uid"))
    }
}

final class ProviderSettingsTests: XCTestCase {
    func testNewInstallsStartOnAFreeProvider() {
        XCTAssertEqual(AppSettings().answerProvider, .gemini)
        XCTAssertNotEqual(AppSettings().answerProvider.costNote, "paid")
    }

    func testModelNamesFallBackToProviderDefaultsAndCanBeOverridden() {
        var s = AppSettings()
        for provider in AnswerProvider.allCases {
            XCTAssertEqual(s.modelName(for: provider), provider.defaultModel)
        }
        s.setModelName("  my-model ", for: .groq)
        s.setModelName("claude-x", for: .anthropic)
        XCTAssertEqual(s.modelName(for: .groq), "my-model")
        XCTAssertEqual(s.modelName(for: .anthropic), "claude-x")
        XCTAssertEqual(s.modelName(for: .gemini), AnswerProvider.gemini.defaultModel, "other providers are unaffected")
        s.setModelName("   ", for: .groq)
        XCTAssertEqual(s.modelName(for: .groq), AnswerProvider.groq.defaultModel, "blank means default")
    }

    func testProviderAndModelsSurviveRoundTripAndUnknownProviderFallsBack() throws {
        var s = AppSettings(answerProvider: .ollama)
        s.setModelName("qwen2.5:7b", for: .ollama)
        let back = try JSONDecoder().decode(AppSettings.self, from: try JSONEncoder().encode(s))
        XCTAssertEqual(back.answerProvider, .ollama)
        XCTAssertEqual(back.modelName(for: .ollama), "qwen2.5:7b")

        let unknown = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"answerProvider":"nonexistent"}"#.utf8))
        XCTAssertEqual(unknown.answerProvider, AppSettings.defaultProvider)
    }

    func testProviderMetadataIsConsistent() {
        for provider in AnswerProvider.allCases {
            XCTAssertFalse(provider.displayName.isEmpty)
            XCTAssertFalse(provider.defaultModel.isEmpty)
            XCTAssertFalse(provider.keyHelpText.isEmpty)
            XCTAssertNotNil(provider.keyHelpURL)
            XCTAssertEqual(provider.needsKey, provider.secretKey != nil)
            XCTAssertGreaterThan(provider.maxTokens, 0)
            if let url = provider.baseURL {
                XCTAssertTrue(url.scheme == "https" || (provider == .ollama && url.host == "localhost"), "\(provider) must use https")
            } else {
                XCTAssertEqual(provider, .anthropic)
            }
        }
        XCTAssertEqual(Set(AnswerProvider.allCases.compactMap(\.secretKey)).count, AnswerProvider.allCases.filter(\.needsKey).count,
                       "every provider needs its own Keychain slot")
        XCTAssertFalse(AnswerProvider.ollama.needsKey)
    }

    func testFactoryPicksTheRightEngine() {
        XCTAssertTrue(AnswerEngineFactory.make(provider: .anthropic, apiKey: "k", model: "") is AnthropicAnswerEngine)
        for provider in [AnswerProvider.gemini, .groq, .openRouter, .ollama] {
            let engine = AnswerEngineFactory.make(provider: provider, apiKey: "", model: " ")
            let primary: AnswerEngine?
            if provider.fallbackModels.isEmpty {
                primary = engine
            } else {
                primary = (engine as? FallbackAnswerEngine)?.engines.first
            }
            let compatible = primary as? OpenAICompatibleAnswerEngine
            XCTAssertNotNil(compatible, "\(provider)")
            XCTAssertEqual(compatible?.model, provider.defaultModel, "blank model falls back to the default")
            XCTAssertEqual(compatible?.baseURL, provider.baseURL)
        }
    }

    func testBackupModelsAreDistinctFromThePrimary() {
        for provider in AnswerProvider.allCases {
            XCTAssertFalse(provider.fallbackModels.contains(provider.defaultModel), "\(provider): backups must differ from the primary")
            XCTAssertEqual(Set(provider.fallbackModels).count, provider.fallbackModels.count)
        }
        XCTAssertFalse(AnswerProvider.gemini.fallbackModels.isEmpty, "Gemini's free tier needs backups for demand spikes")
    }

    private func models(_ engine: AnswerEngine) -> [String]? {
        (engine as? FallbackAnswerEngine)?.engines.compactMap { ($0 as? OpenAICompatibleAnswerEngine)?.model }
    }

    func testFactoryOrdersPrimaryThenDefaultThenBackups() {
        // Default model chosen: primary (retried once), then the provider's backups.
        XCTAssertEqual(models(AnswerEngineFactory.make(provider: .gemini, apiKey: "k", model: "")),
                       ["gemini-3.5-flash-lite", "gemini-3.5-flash-lite", "gemini-3.6-flash", "gemini-flash-latest"])
        // A custom model that is also a backup is not listed twice; the default becomes a backup.
        XCTAssertEqual(models(AnswerEngineFactory.make(provider: .gemini, apiKey: "k", model: "gemini-3.6-flash")),
                       ["gemini-3.6-flash", "gemini-3.6-flash", "gemini-3.5-flash-lite", "gemini-flash-latest"])
        // A mistyped model falls back to the default instead of failing outright.
        XCTAssertEqual(models(AnswerEngineFactory.make(provider: .ollama, apiKey: "", model: "typo:1b")),
                       ["typo:1b", "typo:1b", "llama3.1:8b"])
        // Nothing to fall back to: a single plain engine.
        XCTAssertTrue(AnswerEngineFactory.make(provider: .ollama, apiKey: "", model: "") is OpenAICompatibleAnswerEngine)
    }
}

final class InterviewLanguageTests: XCTestCase {
    func testMappingsForSpeechAndAnswers() {
        XCTAssertEqual(InterviewLanguage.russian.deepgramCode, "ru")
        XCTAssertEqual(InterviewLanguage.english.deepgramCode, "en")
        XCTAssertEqual(InterviewLanguage.auto.deepgramCode, "multi")
        XCTAssertNil(InterviewLanguage.auto.answerLanguageName)
        XCTAssertEqual(InterviewLanguage.russian.answerLanguageName, "Russian")
        XCTAssertEqual(InterviewLanguage.english.answerLanguageName, "English")
    }

    func testLegacyFreeTextIsMigratedAndUnknownBecomesAuto() throws {
        func decode(_ json: String) throws -> InterviewLanguage {
            try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)).interviewLanguage
        }
        XCTAssertEqual(try decode(#"{"language":"Russian"}"#), .russian)
        XCTAssertEqual(try decode(#"{"language":" english "}"#), .english)
        XCTAssertEqual(try decode(#"{"language":"German"}"#), .auto)
        XCTAssertEqual(try decode(#"{"interviewLanguage":"english","language":"Russian"}"#), .english, "new key wins")
        XCTAssertEqual(try decode("{}"), .auto)
    }
}

final class AnswerKeySetupTests: XCTestCase {
    private let granted = FakePermissionsService(microphone: .granted, screenRecording: .granted)

    func testOnlyTheChosenProvidersKeyCounts() throws {
        let secrets = InMemorySecretStore()
        try secrets.set("a", for: .anthropicAPIKey)
        try secrets.set("d", for: .deepgramAPIKey)
        XCTAssertEqual(SetupState.current(permissions: granted, secrets: secrets, provider: .gemini).missing, [.answerKey])
        XCTAssertTrue(SetupState.current(permissions: granted, secrets: secrets, provider: .anthropic).isReady)
    }

    func testOllamaNeedsNoKey() throws {
        let secrets = InMemorySecretStore()
        try secrets.set("d", for: .deepgramAPIKey)
        XCTAssertTrue(SetupState.current(permissions: granted, secrets: secrets, provider: .ollama).isReady)
    }
}
