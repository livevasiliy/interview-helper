import Carbon.HIToolbox
import XCTest

/// XCUITest types through the active keyboard layout, so with a Russian layout on, ordinary text fields
/// receive the wrong characters (secure fields force a Latin layout, which hid the problem). The suite
/// switches to the ABC layout for its run and puts the user's layout back afterwards.
enum KeyboardLayout {
    private static var saved: TISInputSource?

    static func useABC() {
        guard saved == nil else { return }
        saved = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        select(id: "com.apple.keylayout.ABC")
    }

    static func restore() {
        guard let saved else { return }
        TISSelectInputSource(saved)
        self.saved = nil
    }

    private static func select(id: String) {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else { return }
        TISSelectInputSource(source)
    }
}

/// Base class: launches the app in its test mode (see App/Testing/UITestMode.swift) and offers
/// small helpers. Every test starts from a clean, English, fully faked app unless it says otherwise.
class UITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        KeyboardLayout.useABC()
    }

    override func tearDown() {
        app?.terminate()
        KeyboardLayout.restore()
        super.tearDown()
    }

    @discardableResult
    func launch(_ flags: [String] = []) -> XCUIApplication {
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + flags
        app.launch()
        return app
    }

    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func tab(_ name: String) -> XCUIElement {
        app.tabs[name]
    }

    func openSettingsTab() {
        let t = tab("Settings")
        XCTAssertTrue(t.waitForExistence(timeout: 15), "Settings tab not found")   // the first launch of a run is slow
        t.click()
    }

    /// Waits until `element`'s label contains `text` (the label of a Text is its string).
    func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 8,
                      file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed,
                       "expected \(element) to contain \"\(text)\", has label \"\(element.label)\"", file: file, line: line)
    }

    /// Waits until some element with `id` has a label containing `text` (for answers made of several lines).
    func waitForAny(_ id: String, containing text: String, timeout: TimeInterval = 8,
                    file: StaticString = #filePath, line: UInt = #line) {
        let match = app.descendants(matching: .any).matching(identifier: id)
            .containing(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: timeout), "no \(id) element contains \"\(text)\"", file: file, line: line)
    }

    func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 5,
                              file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
                       "\(element) is still there", file: file, line: line)
    }

    func choose(_ title: String, in popUp: XCUIElement) {
        XCTAssertTrue(popUp.waitForExistence(timeout: 5), "\(popUp) not found")
        popUp.click()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "menu item \"\(title)\" not found")
        item.click()
    }

    /// Scrolls the Settings window's form until `element` is clearly on screen: clickable and not hugging the
    /// bottom edge, where a click can land on the border instead of the control.
    func scrollIntoView(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(element) not found", file: file, line: line)
        let form = app.windows["Interview Helper"].scrollViews.firstMatch
        for _ in 0..<30 {
            let frame = element.frame, area = form.frame
            if element.isHittable && frame.minY > area.minY + 20 && frame.maxY < area.maxY - 60 { break }
            // Down when the element is below or hugging the bottom edge, up when it slid past the top.
            form.scroll(byDeltaX: 0, deltaY: frame.minY < area.minY + 20 && frame.minY > area.minY - 4_000 ? 120 : -120)
        }
        XCTAssertTrue(element.isHittable, "\(element) never became visible", file: file, line: line)
    }

    /// True when `element` sits inside the Settings window (the overlay is a separate panel).
    private func isInSettingsWindow(_ element: XCUIElement) -> Bool {
        let window = app.windows["Interview Helper"]
        return window.exists && window.frame.intersects(element.frame)
    }

    func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "\(field) not found")
        if isInSettingsWindow(field) { scrollIntoView(field) }
        Thread.sleep(forTimeInterval: 0.4)   // a closing pop-up menu or a freshly drawn field can still hold focus
        field.click()
        field.typeText(text)
    }
}
