import XCTest

/// The Settings tab: the About-you fields, language and updates.
final class SettingsUITests: UITestCase {
    func testAboutYouFieldsPersistAcrossRelaunch() {
        launch()
        openSettingsTab()
        type("PHP developer, 8 years", into: app.textViews["about-you"])
        type("PHP and React.js interview", into: app.textViews["ai-help"])
        app.terminate()

        launch(["--ui-keep-state"])
        openSettingsTab()
        XCTAssertTrue(app.textViews["about-you"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews["about-you"].value as? String, "PHP developer, 8 years")
        XCTAssertEqual(app.textViews["ai-help"].value as? String, "PHP and React.js interview")
    }

    func testSwitchingTheInterfaceToRussianTranslatesTheWindow() {
        launch()
        openSettingsTab()
        choose("Русский", in: app.popUpButtons["ui-language"])
        XCTAssertTrue(app.tabs["Подготовка"].waitForExistence(timeout: 5), "the Setup tab should now be called Подготовка")
    }

    func testManualUpdateCheckReportsUpToDate() {
        launch()
        openSettingsTab()
        element("updates-check").click()
        waitForLabel(element("updates-status"), containing: "latest version")
        XCTAssertFalse(element("updates-install").exists)
    }

    func testAvailableUpdateShowsTheInstallButton() {
        launch(["--ui-update=9.9.9"])
        openSettingsTab()
        XCTAssertTrue(element("updates-install").waitForExistence(timeout: 8))
        waitForLabel(element("updates-status"), containing: "9.9.9")
    }
}

/// Switching the interface language must re-translate everything on screen, not just what happens to redraw.
final class LanguageSwitchUITests: UITestCase {
    /// Texts that are meant to stay in their own language.
    private let allowed: Set<String> = ["Русский", "English"]

    private func visibleTexts() -> [String] {
        var texts: [String] = []
        let queries: [XCUIElementQuery] = [app.staticTexts, app.buttons, app.checkBoxes, app.popUpButtons,
                                           app.tabs, app.menuItems, app.textFields, app.segmentedControls.buttons]
        for query in queries {
            for element in query.allElementsBoundByIndex {
                for text in [element.label, (element.value as? String) ?? "", element.placeholderValue ?? ""] where !text.isEmpty {
                    texts.append(text)
                }
            }
        }
        return texts
    }

    private func cyrillic(in texts: [String]) -> [String] {
        texts.filter { text in
            !allowed.contains(text) && !text.hasPrefix("System default (")   // carries the real microphone name
                && text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        }
    }

    func testSwitchingFromRussianToEnglishLeavesNoRussianText() {
        launch(["--ui-seed-keys", "--ui-language=ru", "--ui-update=9.9.9"])
        XCTAssertTrue(app.tabs["Подготовка"].waitForExistence(timeout: 8), "the test starts in Russian")
        app.tabs["Настройки"].click()
        waitForLabel(element("updates-status"), containing: "9.9.9")   // a stored status, the riskiest case

        choose("English", in: app.popUpButtons["ui-language"])
        XCTAssertTrue(app.tabs["Setup"].waitForExistence(timeout: 5), "tabs are translated")
        sleep(1)

        let settingsLeft = cyrillic(in: visibleTexts())
        XCTAssertTrue(settingsLeft.isEmpty, "Russian text left on Settings after switching to English: \(settingsLeft)")

        app.tabs["Setup"].click()
        sleep(1)
        let setupLeft = cyrillic(in: visibleTexts())
        XCTAssertTrue(setupLeft.isEmpty, "Russian text left on Setup after switching to English: \(setupLeft)")
    }

    func testSwitchingFromEnglishToRussianLeavesNoEnglishChrome() {
        launch(["--ui-seed-keys", "--ui-update=9.9.9"])
        openSettingsTab()
        waitForLabel(element("updates-status"), containing: "9.9.9")
        choose("Русский", in: app.popUpButtons["ui-language"])
        XCTAssertTrue(app.tabs["Подготовка"].waitForExistence(timeout: 5))
        // The Updates section is where text used to stay behind.
        waitForLabel(element("updates-status"), containing: "Доступна версия")
        XCTAssertTrue(app.staticTexts["Обновления"].exists)
        XCTAssertFalse(app.staticTexts["Updates"].exists)
    }
}
