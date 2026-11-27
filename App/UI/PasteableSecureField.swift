import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A secure text field for API keys that handles ⌘V, ⌘C, ⌘X, ⌘A and ⌘Z itself while it is being edited,
/// so pasting a key works no matter how the app's menus are set up (the app has no standard Edit menu
/// when it runs as a menu bar app, and SwiftUI's SecureField relies on one).
struct PasteableSecureField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    var identifier = ""

    func makeNSView(context: Context) -> KeyField {
        let field = KeyField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.setAccessibilityIdentifier(identifier)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: KeyField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PasteableSecureField
        init(_ parent: PasteableSecureField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

/// ⌘V, ⌘C, ⌘X, ⌘A, ⌘Z for a field that is being edited, matched by the physical key (not the typed
/// character), so they also work while a Russian or other non-Latin layout is active.
enum EditShortcuts {
    static func handle(_ event: NSEvent, in field: NSTextField) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let editor = field.currentEditor() as? NSTextView else { return false }
        switch Int(event.keyCode) {
        case kVK_ANSI_V: editor.paste(nil)
        case kVK_ANSI_C: editor.copy(nil)
        case kVK_ANSI_X: editor.cut(nil)
        case kVK_ANSI_A: editor.selectAll(nil)
        case kVK_ANSI_Z: editor.undoManager?.undo()
        default: return false
        }
        // The delegate hears about the new text through the normal editing notification.
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        return true
    }
}

final class KeyField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        EditShortcuts.handle(event, in: self) || super.performKeyEquivalent(with: event)
    }
}
