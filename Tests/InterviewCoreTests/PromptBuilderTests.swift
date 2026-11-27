import XCTest
@testable import InterviewCore

final class PromptBuilderTests: XCTestCase {
    func testIncludesResumeRoleAndQuestion() {
        let b = PromptBuilder(resume: "10 years of Swift", roleContext: "Senior iOS at Acme")
        let p = b.build(question: "Why Acme?", history: [])
        XCTAssertTrue(p.system.contains("10 years of Swift"))
        XCTAssertTrue(p.system.contains("Senior iOS at Acme"))
        XCTAssertEqual(p.messages.count, 1)
        XCTAssertEqual(p.messages[0].role, .user)
        XCTAssertTrue(p.messages[0].content.hasSuffix("Why Acme?"))
    }

    func testOmitsEmptySections() {
        let p = PromptBuilder().build(question: "Hi?", history: [])
        XCTAssertFalse(p.system.contains("resume"))
        XCTAssertFalse(p.system.contains("What the candidate wants help with"))
    }

    func testHistoryIsLimitedToMostRecentTurns() {
        let history = (1...10).map { Turn(speaker: $0 % 2 == 0 ? .me : .interviewer, text: "turn\($0)") }
        let p = PromptBuilder(maxHistoryTurns: 3).build(question: "Q?", history: history)
        let content = p.messages[0].content
        XCTAssertFalse(content.contains("turn7"))
        XCTAssertTrue(content.contains("turn8"))
        XCTAssertTrue(content.contains("turn10"))
        XCTAssertTrue(content.contains("Candidate: turn8"))
        XCTAssertTrue(content.contains("Interviewer: turn9"))
    }

    func testResumeIsTruncated() {
        let long = String(repeating: "x", count: 500)
        let p = PromptBuilder(resume: long, maxResumeCharacters: 100).build(question: "Q?", history: [])
        XCTAssertFalse(p.system.contains(String(repeating: "x", count: 101)))
        XCTAssertTrue(p.system.contains(String(repeating: "x", count: 100)))
    }

    func testLanguageInstruction() {
        XCTAssertTrue(PromptBuilder(language: "Russian").build(question: "Q?", history: []).system.contains("Always answer in Russian."))
        XCTAssertTrue(PromptBuilder().build(question: "Q?", history: []).system.contains("same language"))
        XCTAssertTrue(PromptBuilder(language: "  ").build(question: "Q?", history: []).system.contains("same language"))
    }

    func testZeroHistoryTurnsOmitsHistory() {
        let p = PromptBuilder(maxHistoryTurns: 0).build(question: "Q?", history: [Turn(speaker: .me, text: "hello")])
        XCTAssertFalse(p.messages[0].content.contains("Recent conversation"))
    }
}
