import AppKit
import InterviewCore

/// Invisible strip along a window edge or corner. It shows the matching resize cursor and resizes the
/// window itself. The overlay panel never activates the app, and in that state macOS shows no resize
/// cursors for a panel's own border, so these handles do the job explicitly.
final class ResizeHandleView: NSView {
    static let edgeThickness: CGFloat = 7
    static let cornerSize: CGFloat = 18

    let edge: ResizeEdge
    private var startFrame = NSRect.zero
    private var startMouse = NSPoint.zero

    init(edge: ResizeEdge, frame: NSRect) {
        self.edge = edge
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Never let the window-drag-by-background behaviour swallow a resize drag.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Cursor

    private var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch edge {
            case .left: position = .left
            case .right: position = .right
            case .top: position = .top
            case .bottom: position = .bottom
            case .topLeft: position = .topLeft
            case .topRight: position = .topRight
            case .bottomLeft: position = .bottomLeft
            case .bottomRight: position = .bottomRight
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        switch edge {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair   // no public diagonal cursor before macOS 15
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // `.activeAlways` is what makes cursor changes work while the app is not frontmost.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        ))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }
    override func mouseEntered(with event: NSEvent) { cursor.set() }
    override func mouseMoved(with event: NSEvent) { cursor.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    // MARK: Resizing

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startFrame = window.frame
        startMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let frame = WindowResize.resized(
            startFrame,
            edge: edge,
            dx: mouse.x - startMouse.x,
            dy: mouse.y - startMouse.y,
            minSize: window.minSize
        )
        window.setFrame(frame, display: true)
        cursor.set()
    }

    override func mouseUp(with event: NSEvent) { cursor.set() }

    // MARK: Installation

    /// Adds the four edge strips and four corner squares on top of `container`'s content.
    static func install(in container: NSView) {
        let t = edgeThickness
        let c = cornerSize
        let b = container.bounds

        func add(_ edge: ResizeEdge, _ rect: NSRect, _ mask: NSView.AutoresizingMask) {
            let handle = ResizeHandleView(edge: edge, frame: rect)
            handle.autoresizingMask = mask
            container.addSubview(handle)
        }

        // Edges first, corners last so corners win where they overlap.
        add(.left, NSRect(x: 0, y: c, width: t, height: b.height - 2 * c), [.height, .maxXMargin])
        add(.right, NSRect(x: b.width - t, y: c, width: t, height: b.height - 2 * c), [.height, .minXMargin])
        add(.bottom, NSRect(x: c, y: 0, width: b.width - 2 * c, height: t), [.width, .maxYMargin])
        add(.top, NSRect(x: c, y: b.height - t, width: b.width - 2 * c, height: t), [.width, .minYMargin])
        add(.bottomLeft, NSRect(x: 0, y: 0, width: c, height: c), [.maxXMargin, .maxYMargin])
        add(.bottomRight, NSRect(x: b.width - c, y: 0, width: c, height: c), [.minXMargin, .maxYMargin])
        add(.topLeft, NSRect(x: 0, y: b.height - c, width: c, height: c), [.maxXMargin, .minYMargin])
        add(.topRight, NSRect(x: b.width - c, y: b.height - c, width: c, height: c), [.minXMargin, .minYMargin])
    }
}
