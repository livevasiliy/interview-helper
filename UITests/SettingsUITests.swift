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
