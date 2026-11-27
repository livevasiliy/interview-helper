import XCTest
@testable import InterviewCore

final class UpdateCheckerTests: XCTestCase {
    func testVersionParsingAndOrdering() {
        XCTAssertEqual(AppVersion("v0.3.0")?.description, "0.3.0")
        XCTAssertLessThan(AppVersion("0.9.0")!, AppVersion("0.10.0")!)
        XCTAssertLessThan(AppVersion("1.2")!, AppVersion("1.2.1")!)
        XCTAssertEqual(AppVersion("1.2")!, AppVersion("1.2.0")!)
        XCTAssertEqual(AppVersion("1.0.0-beta.1")!, AppVersion("1.0.0")!)
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("1..2"))
    }

    private func checker(status: Int = 200, body: String) -> UpdateChecker {
        StubURLProtocol.reset(status: status, chunks: [body])
        return UpdateChecker(session: StubURLProtocol.session())
    }

    private func release(tag: String, extra: String = "") -> String {
        #"{"tag_name":"\#(tag)","html_url":"https://github.com/o/r/releases/tag/\#(tag)","body":"notes"\#(extra)}"#
    }

    func testNewerReleaseIsReported() async throws {
        let c = checker(body: release(tag: "v0.4.0"))
        let found = try await c.newerRelease(than: "0.3.0")
        XCTAssertEqual(found?.tag, "v0.4.0")
        XCTAssertEqual(found?.notes, "notes")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.host, "api.github.com")
        XCTAssertNil(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testSameOrOlderReleaseIsNotAnUpdate() async throws {
        let same = try await checker(body: release(tag: "v0.3.0")).newerRelease(than: "0.3.0")
        XCTAssertNil(same)
        let older = try await checker(body: release(tag: "v0.2.0")).newerRelease(than: "0.3.0")
        XCTAssertNil(older)
    }

    func testBadAnswersAreErrors() async {
        for (status, body) in [(404, "{}"), (200, "not json"), (200, release(tag: "nightly")),
                               (200, release(tag: "v9.0.0", extra: #","prerelease":true"#))] {
            do {
                _ = try await checker(status: status, body: body).newerRelease(than: "0.3.0")
                XCTFail("expected an error for \(status) \(body)")
            } catch {}
        }
    }

    func testRateLimitMessageIsFriendly() {
        XCTAssertEqual(UpdateError.http(403), .http(403))
        XCTAssertNotNil(UpdateError.http(429).errorDescription)
    }

    func testCheckForUpdatesSettingDefaultsOnAndSurvivesOldPayloads() throws {
        XCTAssertTrue(AppSettings().checkForUpdates)
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).checkForUpdates)
        var s = AppSettings(); s.checkForUpdates = false
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s)).checkForUpdates)
    }
}
