import Carbon.HIToolbox

/// The app's global keyboard shortcuts, defined once so the menu, overlay hints and Settings never disagree.
enum Shortcut: CaseIterable {
    case startStop
    case answerNow
    case analyzeScreen
    case toggleOverlay
    case openSettings

    /// Shown in the UI. ⌃ Control, ⌥ Option, ↩ Return.
    var symbols: String {
        switch self {
        case .startStop: return "⌃⌥Space"
        case .answerNow: return "⌃⌥↩"
        case .analyzeScreen: return "⌃⌥S"
        case .toggleOverlay: return "⌃⌥O"
        case .openSettings: return "⌃⌥,"
        }
    }

    /// Full description for Settings and the menu.
    var title: String {
        switch self {
        case .startStop: return tr("Start / stop session")
        case .answerNow: return tr("Answer now: send what was just heard")
        case .analyzeScreen: return tr("Analyze the screen: solve the task you see")
        case .toggleOverlay: return tr("Show / hide overlay")
        case .openSettings: return tr("Open settings (⌘, also works while this app is active)")
        }
    }

    /// Short label for the overlay's hint line.
    var shortTitle: String {
        switch self {
        case .startStop: return tr("start / stop")
        case .answerNow: return tr("answer now")
        case .analyzeScreen: return tr("screen")
        case .toggleOverlay: return tr("hide")
        case .openSettings: return tr("settings")
        }
    }

    var keyCode: Int {
        switch self {
        case .startStop: return kVK_Space
        case .answerNow: return kVK_Return
        case .analyzeScreen: return kVK_ANSI_S
        case .toggleOverlay: return kVK_ANSI_O
        case .openSettings: return kVK_ANSI_Comma
        }
    }

    var modifiers: Int { controlKey | optionKey }
}
