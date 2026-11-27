import XCTest

/// The floating overlay during a session, driven by the canned pipeline (an interviewer question arrives
/// about a second after start; answers are deterministic).
final class OverlayUITests: UITestCase {
    func testOverlayIsIdleBeforeASessionStarts() {
        launch(["--ui-seed-keys"])
        waitForLabel(element("overlay-status"), containing: "Not listening")
    }

    func testSessionListensAndAnswersTheDetectedQuestion() {
        launch(["--ui-seed-keys", "--ui-autostart"])
        waitForLabel(element("overlay-status"), containing: "Listening")
        waitForLabel(element("overlay-question"), containing: "dependency injection")
        waitForAny("overlay-answer-line", containing: "Canned answer")
    }

    func testTypedQuestionIsAnswered() {
        launch(["--ui-seed-keys", "--ui-autostart"])
        waitForLabel(element("overlay-status"), containing: "Listening")

        type("What is a closure?\n", into: element("typed-question"))
        waitForLabel(element("overlay-question"), containing: "What is a closure?")
        waitForAny("overlay-answer-line", containing: "closure")
    }

    func testScreenAnalysisAnswersWithCode() {
        launch(["--ui-seed-keys", "--ui-autostart"])
        waitForLabel(element("overlay-status"), containing: "Listening")

        element("overlay-screen").click()
        waitForLabel(element("overlay-question"), containing: "Screenshot")
        waitForAny("overlay-answer-line", containing: "one pass")
        waitForAny("overlay-code", containing: "screen solved")
    }

    func testOverlayCanBeHiddenWithItsButton() {
        launch(["--ui-seed-keys"])
        XCTAssertTrue(element("overlay-hide").waitForExistence(timeout: 8))
        element("overlay-hide").click()
        waitForDisappearance(element("overlay-status"))
    }
}
