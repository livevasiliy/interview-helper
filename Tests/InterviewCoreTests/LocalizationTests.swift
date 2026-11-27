import XCTest
@testable import InterviewCore

final class LocalizationTests: XCTestCase {
    override func tearDown() {
        L10n.language = .english   // never leak a language into other tests
        super.tearDown()
    }

    // MARK: Engine

    func testEnglishIsTheSourceAndRussianTranslates() {
        L10n.language = .english
        XCTAssertEqual(L10n.tr("Save"), "Save")
        L10n.language = .russian
        XCTAssertEqual(L10n.tr("Save"), "Сохранить")
    }

    func testMissingTranslationFallsBackToTheEnglishText() {
        L10n.language = .russian
        XCTAssertEqual(L10n.tr("A string nobody translated"), "A string nobody translated")
    }

    func testFormatting() {
        L10n.language = .russian
        XCTAssertEqual(L10n.tr("Request failed (HTTP %ld): %@", 503, "busy"), "Запрос не удался (HTTP 503): busy")
        L10n.language = .english
        XCTAssertEqual(L10n.tr("Request failed (HTTP %ld): %@", 503, "busy"), "Request failed (HTTP 503): busy")
    }

    func testAutoFollowsTheSystemLanguage() {
        XCTAssertEqual(UILanguage.auto.resolved(preferredLanguages: ["ru-RU", "en-US"]), .russian)
        XCTAssertEqual(UILanguage.auto.resolved(preferredLanguages: ["en-US", "ru-RU"]), .english)
        XCTAssertEqual(UILanguage.auto.resolved(preferredLanguages: ["de-DE"]), .english)
        XCTAssertEqual(UILanguage.auto.resolved(preferredLanguages: []), .english)
        XCTAssertEqual(UILanguage.russian.resolved(preferredLanguages: ["en-US"]), .russian)
        XCTAssertEqual(UILanguage.english.resolved(preferredLanguages: ["ru-RU"]), .english)
    }

    func testCoreMessagesFollowTheLanguage() {
        L10n.language = .russian
        XCTAssertEqual(ProviderError.unauthorized.errorDescription, "Ключ API отклонён. Проверьте его в настройках.")
        XCTAssertEqual(AnswerProvider.ollama.costNote, "бесплатно, офлайн")
        XCTAssertEqual(AnswerProvider.gemini.pickerTitle, "Google Gemini · бесплатный тариф")
        XCTAssertEqual(InterviewLanguage.auto.displayName, "Авто")
        XCTAssertEqual(InterviewLanguage.russian.displayName, "Русский", "a language is named in itself")
        L10n.language = .english
        XCTAssertEqual(ProviderError.unauthorized.errorDescription, "The API key was rejected. Check it in Settings.")
        XCTAssertEqual(UILanguage.auto.displayName, "Auto (system)")
    }

    func testUILanguageSettingRoundTripsAndDefaultsToAuto() throws {
        XCTAssertEqual(AppSettings().uiLanguage, .auto)
        let data = try JSONEncoder().encode(AppSettings(uiLanguage: .russian))
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).uiLanguage, .russian)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).uiLanguage, .auto)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"uiLanguage":"klingon"}"#.utf8)).uiLanguage, .auto)
    }

    // MARK: Table quality

    private func placeholders(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(?:ld|d|@|f|\\.\\d+f)")
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { String(text[Range($0.range, in: text)!]) }
    }

    func testEveryTranslationIsNonEmptyAndKeepsItsPlaceholders() {
        for (english, russian) in Translations.russian {
            XCTAssertFalse(russian.trimmingCharacters(in: .whitespaces).isEmpty, "empty translation for: \(english)")
            XCTAssertEqual(placeholders(english), placeholders(russian), "placeholders differ for: \(english)")
        }
    }

    // MARK: Source guard: no forgotten, misspelled or unused strings

    /// Every `tr("…")` literal found in the sources, with the file it came from.
    private func sourceLiterals() throws -> (used: Set<String>, root: URL)? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.appendingPathComponent("Sources/InterviewCore").path),
              fm.fileExists(atPath: root.appendingPathComponent("App").path)
        else { return nil }   // sources not next to the tests (e.g. an installed test bundle)

        let regex = try NSRegularExpression(pattern: #"\btr\(\s*"((?:[^"\\]|\\.)*)""#)
        var used = Set<String>()
        for folder in ["Sources/InterviewCore", "App"] {
            guard let walker = fm.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" && url.lastPathComponent != "Translations.swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                let range = NSRange(text.startIndex..., in: text)
                for match in regex.matches(in: text, range: range) {
                    let key = String(text[Range(match.range(at: 1), in: text)!])
                        .replacingOccurrences(of: "\\\"", with: "\"")
                    used.insert(key)
                }
            }
        }
        return (used, root)
    }

    func testEveryTrCallHasARussianTranslation() throws {
        guard let (used, _) = try sourceLiterals() else { throw XCTSkip("sources not available") }
        XCTAssertGreaterThan(used.count, 50, "the scan should find the app's strings")
        let missing = used.filter { Translations.russian[$0] == nil }.sorted()
        XCTAssertTrue(missing.isEmpty, "no Russian translation for:\n" + missing.joined(separator: "\n"))
    }

    func testNoTranslationIsUnused() throws {
        guard let (used, _) = try sourceLiterals() else { throw XCTSkip("sources not available") }
        let unused = Translations.russian.keys.filter { !used.contains($0) }.sorted()
        XCTAssertTrue(unused.isEmpty, "translation keys never used in a tr() call (typo?):\n" + unused.joined(separator: "\n"))
    }
}
