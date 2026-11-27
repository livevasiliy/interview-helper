import XCTest
@testable import InterviewCore

final class QuestionDetectorTests: XCTestCase {
    private func seg(_ text: String, _ start: TimeInterval, _ end: TimeInterval,
                     speaker: Speaker = .interviewer, final: Bool = true) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, text: text, isFinal: final, start: start, end: end)
    }

    func testQuestionMarkEmitsImmediately() {
        var d = QuestionDetector()
        let q = d.ingest(seg("What is a closure?", 0, 2))
        XCTAssertEqual(q?.text, "What is a closure?")
    }

    func testStatementWithoutCueIsNotEmitted() {
        var d = QuestionDetector()
        XCTAssertNil(d.ingest(seg("Thanks for joining today.", 0, 2)))
        XCTAssertNil(d.flush(now: 5))
    }

    func testCueWithoutQuestionMarkEmitsAfterSilence() {
        var d = QuestionDetector()
        XCTAssertNil(d.ingest(seg("Tell me about a difficult project", 0, 3)))
        XCTAssertNil(d.flush(now: 3.3), "silence below threshold must not emit")
        XCTAssertEqual(d.flush(now: 3.8)?.text, "Tell me about a difficult project")
        XCTAssertNil(d.flush(now: 10), "buffer must be cleared after emit")
    }

    func testMultiSegmentQuestionIsMerged() {
        var d = QuestionDetector()
        XCTAssertNil(d.ingest(seg("Walk me through your last project", 0, 3)))
        let q = d.ingest(seg("and what was your role there?", 3.2, 5))
        XCTAssertEqual(q?.text, "Walk me through your last project and what was your role there?")
    }

    func testPartialsAreIgnored() {
        var d = QuestionDetector()
        XCTAssertNil(d.ingest(seg("What is", 0, 1, final: false)))
        XCTAssertNil(d.flush(now: 5))
    }

    func testCandidateSpeechClearsBuffer() {
        var d = QuestionDetector()
        XCTAssertNil(d.ingest(seg("Describe your approach", 0, 2)))
        XCTAssertNil(d.ingest(seg("Sure, so I would start by", 2.1, 4, speaker: .me)))
        XCTAssertNil(d.flush(now: 10))
    }

    func testGapBeforeNextSegmentClosesPreviousUtterance() {
        var d = QuestionDetector()
        XCTAssertNil(d.ingest(seg("Explain dependency injection", 0, 3)))
        let q = d.ingest(seg("Okay, moving on.", 5, 6))
        XCTAssertEqual(q?.text, "Explain dependency injection")
    }

    func testCueMustBeOnWordBoundary() {
        var d = QuestionDetector()
        // "whatever" starts with "what" but is not a question cue.
        XCTAssertNil(d.ingest(seg("Whatever works for you.", 0, 2)))
        XCTAssertNil(d.flush(now: 5))
    }

    func testRussianQuestions() {
        var d = QuestionDetector()
        XCTAssertEqual(d.ingest(seg("Что такое замыкание?", 0, 2))?.text, "Что такое замыкание?")
        XCTAssertNil(d.ingest(seg("Расскажите о вашем опыте", 3, 5)))
        XCTAssertEqual(d.flush(now: 6)?.text, "Расскажите о вашем опыте")
    }

    func testEmptyTextIgnored() {
        var d = QuestionDetector()
        XCTAssertNil(d.ingest(seg("   ", 0, 1)))
    }

    func testTakePendingReturnsAndClearsBufferedSpeech() {
        var d = QuestionDetector()
        XCTAssertNil(d.pendingText)
        XCTAssertNil(d.takePending())
        _ = d.ingest(seg("So about your PHP experience", 0, 2))
        _ = d.ingest(seg("and frameworks", 2.1, 3))
        XCTAssertEqual(d.pendingText, "So about your PHP experience and frameworks")
        XCTAssertEqual(d.takePending(), "So about your PHP experience and frameworks")
        XCTAssertNil(d.pendingText)
        XCTAssertNil(d.flush(now: 100))
    }
}
