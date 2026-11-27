import AppKit

/// Creates the menu bar icon and can tell whether macOS actually shows it.
/// On notched MacBooks a crowded menu bar pushes new icons under the notch, where they are invisible.
@MainActor
enum StatusItemFactory {
    static let name = "InterviewHelper"

    struct Visibility {
        let isVisible: Bool
        let detail: String
    }

    static func make() -> NSStatusItem {
        // Ask for a spot just left of the clock (distance from the right edge, in points) so the icon
        // doesn't start at the crowded, notch-side end of the menu bar. The user can still ⌘-drag it.
        let key = "NSStatusItem Preferred Position \(name)"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(110.0, forKey: key)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = name
        item.isVisible = true
        return item
    }

    static func visibility(of item: NSStatusItem) -> Visibility {
        guard let window = item.button?.window else {
            return Visibility(isVisible: false, detail: "the status item has no window")
        }
        let frame = window.frame
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else {
            return Visibility(isVisible: false, detail: "icon frame \(frame) is outside every screen")
        }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let usable = left.insetBy(dx: -1, dy: -1).contains(frame) || right.insetBy(dx: -1, dy: -1).contains(frame)
            return Visibility(
                isVisible: usable,
                detail: "icon \(frame); notch screen, usable areas left \(left) right \(right)"
            )
        }
        return Visibility(isVisible: window.isVisible, detail: "icon \(frame); screen without a notch, window visible: \(window.isVisible)")
    }

    /// Dev tool (`--diagnose-menubar`): create the icon, wait a moment, report where macOS put it.
    static func diagnose() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let item = make()
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let result = visibility(of: item)
        print("visible: \(result.isVisible)")
        print("detail: \(result.detail)")
        for screen in NSScreen.screens {
            print("screen frame: \(screen.frame)")
        }
    }
}
