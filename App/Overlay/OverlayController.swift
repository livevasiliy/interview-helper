import AppKit
import SwiftUI

/// Floating panel that never takes focus: typing in the interview app keeps working while it is visible.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController {
    private let panel: OverlayPanel

    init(session: SessionCoordinator, appearance: OverlayAppearance) {
        panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 480),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.minSize = NSSize(width: 340, height: 220)

        let root = LiveOverlayView(session: session, appearance: appearance, onHide: { [weak panel] in panel?.orderOut(nil) })
            .background(.regularMaterial)
            .ignoresSafeArea()
        let hosting = NSHostingView(rootView: root)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 480))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        ResizeHandleView.install(in: container)
        panel.contentView = container
        panel.acceptsMouseMovedEvents = true

        // Remembers the user's position and size; first launch goes to the top-right corner.
        if !panel.setFrameUsingName("InterviewHelperOverlay.v2") {
            positionTopRight()
        }
        panel.setFrameAutosaveName("InterviewHelperOverlay.v2")
    }

    var isVisible: Bool { panel.isVisible }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    func toggle() { isVisible ? hide() : show() }

    /// Best effort: asks macOS to exclude the panel from screen sharing and recordings.
    /// Apps that capture through newer APIs may still see it on recent macOS versions.
    func setHiddenFromCapture(_ hidden: Bool) {
        panel.sharingType = hidden ? .none : .readOnly
    }

    private func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 24, y: frame.maxY - size.height - 24))
    }
}
