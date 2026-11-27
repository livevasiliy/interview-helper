import XCTest

/// The Setup tab: keys, providers and the "ready" state. These are the paths where a bug makes the
/// app unusable before the interview even starts.
final class SetupFlowUITests: UITestCase {
    func testFreshLaunchAsksForKeysAndShowsInputFields() {
        launch()
        XCTAssertTrue(element("setup-incomplete").waitForExistence(timeout: 8))
        XCTAssertTrue(element("key-field-geminiAPIKey").exists)
        XCTAssertTrue(element("key-field-deepgramAPIKey").exists)
        XCTAssertFalse(element("setup-ready").exists)
    }

    func testSavedKeyCollapsesToOneLineAndCanBeReplacedAndRemoved() {
        launch()
        type("my-test-gemini-key", into: element("key-field-geminiAPIKey"))
        element("key-save-geminiAPIKey").click()

        // Saved: no input field, a status line with Replace / Remove.
        waitForLabel(element("key-status-geminiAPIKey"), containing: "saved")
        waitForDisappearance(element("key-field-geminiAPIKey"))
        XCTAssertTrue(element("key-replace-geminiAPIKey").exists)

        // Replace brings the field back; Cancel hides it again.
        element("key-replace-geminiAPIKey").click()
        XCTAssertTrue(element("key-field-geminiAPIKey").waitForExistence(timeout: 3))
        element("key-cancel-geminiAPIKey").click()
        waitForDisappearance(element("key-field-geminiAPIKey"))

        // Remove forgets the key and the field is back.
        element("key-remove-geminiAPIKey").click()
        XCTAssertTrue(element("key-field-geminiAPIKey").waitForExistence(timeout: 3))
    }

    func testSetupBecomesReadyWhenBothKeysAreSaved() {
        launch()
        type("test-gemini-key", into: element("key-field-geminiAPIKey"))
        element("key-save-geminiAPIKey").click()
        XCTAssertFalse(element("setup-ready").exists, "the speech key is still missing")

        type("test-deepgram-key", into: element("key-field-deepgramAPIKey"))
        element("key-save-deepgramAPIKey").click()
        XCTAssertTrue(element("setup-ready").waitForExistence(timeout: 5))
    }

    func testChoosingAnotherSpeechProviderRequiresItsOwnKey() {
        launch(["--ui-seed-keys"])
        XCTAssertTrue(element("setup-ready").waitForExistence(timeout: 8))

        choose("Groq Whisper · free tier", in: app.popUpButtons["stt-provider"])
        XCTAssertTrue(element("setup-incomplete").waitForExistence(timeout: 5))
        XCTAssertTrue(element("key-field-groqAPIKey").exists, "Groq has no key yet")

        type("gsk_test_groq_key", into: element("key-field-groqAPIKey"))
        element("key-save-groqAPIKey").click()
        XCTAssertTrue(element("setup-ready").waitForExistence(timeout: 5))
    }

    func testChoosingAnotherAnswerProviderRequiresItsOwnKey() {
        launch(["--ui-seed-keys"])
        XCTAssertTrue(element("setup-ready").waitForExistence(timeout: 8))

        choose("OpenAI · paid", in: app.popUpButtons["answer-provider"])
        XCTAssertTrue(element("key-field-openAIAPIKey").waitForExistence(timeout: 5))
        XCTAssertTrue(element("setup-incomplete").exists)
    }

    func testOllamaNeedsNoAnswerKey() {
        launch(["--ui-seed-keys"])
        choose("Ollama (on this Mac) · free, offline", in: app.popUpButtons["answer-provider"])
        XCTAssertTrue(element("setup-ready").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No key needed"].exists)
    }

    func testDeniedPermissionsKeepSetupIncompleteEvenWithKeys() {
        launch(["--ui-seed-keys", "--ui-permissions=denied"])
        XCTAssertTrue(element("setup-incomplete").waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Open System Settings"].exists, "a denied microphone points to System Settings")
    }

    // MARK: Key validation and pasting

    func testKeyRejectedByTheProviderIsNotSaved() {
        launch()
        type("gemini-rejected-key", into: element("key-field-geminiAPIKey"))
        element("key-save-geminiAPIKey").click()

        waitForLabel(element("key-message-geminiAPIKey"), containing: "did not accept")
        XCTAssertTrue(element("key-field-geminiAPIKey").exists, "the field stays so the key can be fixed")
        XCTAssertFalse(element("key-replace-geminiAPIKey").exists, "nothing was saved")
        XCTAssertFalse(element("setup-ready").exists)
    }

    func testKeyThatCannotBeVerifiedIsSavedWithANote() {
        launch()
        type("gemini-offline-key", into: element("key-field-geminiAPIKey"))
        element("key-save-geminiAPIKey").click()

        waitForLabel(element("key-status-geminiAPIKey"), containing: "saved")
        waitForLabel(element("key-message-geminiAPIKey"), containing: "Could not reach")
    }

    func testKeyWithSpacesIsRefusedBeforeAnyRequest() {
        launch()
        type("two words here", into: element("key-field-geminiAPIKey"))
        element("key-save-geminiAPIKey").click()
        waitForLabel(element("key-message-geminiAPIKey"), containing: "spaces")
        XCTAssertTrue(element("key-field-geminiAPIKey").exists)
    }

    func testTypingAfterAnErrorClearsIt() {
        launch()
        type("gemini-rejected-key", into: element("key-field-geminiAPIKey"))
        element("key-save-geminiAPIKey").click()
        XCTAssertTrue(element("key-message-geminiAPIKey").waitForExistence(timeout: 5))
        element("key-field-geminiAPIKey").typeText("x")
        waitForDisappearance(element("key-message-geminiAPIKey"))
    }

    func testKeyOfAnotherServiceIsSavedWithAWarning() {
        launch()
        type("gsk_abcdefghijklmnop", into: element("key-field-geminiAPIKey"))
        element("key-save-geminiAPIKey").click()
        waitForLabel(element("key-status-geminiAPIKey"), containing: "saved")
        waitForLabel(element("key-message-geminiAPIKey"), containing: "does not look like")
    }

    func testCommandVPastesTheKeyIntoTheField() {
        launch()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("AIzaSy-pasted-with-command-v", forType: .string)

        let field = element("key-field-geminiAPIKey")
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.click()
        field.typeKey("v", modifierFlags: .command)

        XCTAssertTrue(element("key-save-geminiAPIKey").isEnabled, "pasting fills the field, so Save is available")
        element("key-save-geminiAPIKey").click()
        waitForLabel(element("key-status-geminiAPIKey"), containing: "saved")
    }

    func testPasteButtonTakesTheKeyFromTheClipboardAndCleansIt() {
        launch()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("  GEMINI_API_KEY=\"AIzaSy-from-the-clipboard\"\n", forType: .string)

        XCTAssertTrue(element("key-paste-geminiAPIKey").waitForExistence(timeout: 8))
        element("key-paste-geminiAPIKey").click()
        element("key-save-geminiAPIKey").click()
        waitForLabel(element("key-status-geminiAPIKey"), containing: "saved")
        XCTAssertFalse(element("key-message-geminiAPIKey").exists, "a cleaned, well-formed key needs no warning")
    }
}
