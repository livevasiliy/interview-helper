import AppKit
import SwiftUI

/// A text field for the overlay. The overlay panel normally refuses keyboard focus so typing in the
/// interview app keeps working; clicking this field is the one moment the panel may take it,
/// and it gives it back as soon as editing ends (Return, Escape or a click elsewhere).
struct TypedQuestionField: NSViewRepresentable {
    let placeholder: String
    let fontSize: CGFloat
    var onSubmit: (String) -> Void

    func makeNSView(context: Context) -> ClickToTypeField {
        let field = ClickToTypeField()
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("typed-question")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func updateNSView(_ field: ClickToTypeField, context: Context) {
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: fontSize)
        context.coordinator.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSubmit: onSubmit) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onSubmit: (String) -> Void
        init(onSubmit: @escaping (String) -> Void) { self.onSubmit = onSubmit }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? ClickToTypeField else { return false }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    onSubmit(text)
                    field.stringValue = ""
                }
                field.giveUpFocus()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                field.giveUpFocus()
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            (notification.object as? ClickToTypeField)?.giveUpFocus()
        }
    }
}

final class ClickToTypeField: NSTextField {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The overlay panel does not activate the app, so the Edit menu's shortcuts may not reach it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        EditShortcuts.handle(event, in: self) || super.performKeyEquivalent(with: event)
    }

    /// Ends editing and hands the keyboard back; the app that was frontmost never lost activation.
    func giveUpFocus() {
        guard let panel = window as? OverlayPanel else { return }
        panel.makeFirstResponder(nil)
        panel.resignKey()
    }
}
