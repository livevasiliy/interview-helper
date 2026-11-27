import XCTest
@testable import InterviewCore

final class FakesTests: XCTestCase {
    struct Boom: Error {}

    func testFakeTranscriberFiltersBySpeaker() async throws {
        let script = [
            TranscriptSegment(speaker: .interviewer, text: "A", isFinal: true, start: 0, end: 1),
            TranscriptSegment(speaker: .me, text: "B", isFinal: true, start: 1, end: 2),
        ]
        let t = FakeTranscriber(script: script)
        var texts: [String] = []
        for try await s in t.transcribe(audio: AsyncStream { $0.finish() }, speaker: .interviewer) {
            texts.append(s.text)
        }
        XCTAssertEqual(texts, ["A"])
    }

    func testFakeAnswerEngineStreamsThenFails() async {
        let e = FakeAnswerEngine(tokens: ["a", "b"], failure: Boom())
        var got: [String] = []
        do {
            for try await tok in e.answer(for: AnswerPrompt(system: "", messages: [])) { got.append(tok) }
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(error is Boom)
        }
        XCTAssertEqual(got, ["a", "b"])
    }
}
