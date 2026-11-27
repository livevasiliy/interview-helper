import CoreGraphics

public enum ResizeEdge: CaseIterable, Sendable {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight

    var movesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var movesRight: Bool { self == .right || self == .topRight || self == .bottomRight }
    var movesTop: Bool { self == .top || self == .topLeft || self == .topRight }
    var movesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
}

/// Pure geometry for dragging a window edge or corner. Coordinates follow AppKit's screen space
/// (origin bottom-left, y grows upward), so dragging the top edge up gives a positive `dy`.
public enum WindowResize {
    /// - Parameters:
    ///   - dx: mouse movement since the drag began, horizontally (right is positive).
    ///   - dy: mouse movement since the drag began, vertically (up is positive).
    /// The edge opposite to the dragged one never moves, even when a size limit is hit.
    public static func resized(
        _ frame: CGRect,
        edge: ResizeEdge,
        dx: CGFloat,
        dy: CGFloat,
        minSize: CGSize,
        maxSize: CGSize? = nil
    ) -> CGRect {
        var minX = frame.minX, maxX = frame.maxX, minY = frame.minY, maxY = frame.maxY

        if edge.movesLeft { minX += dx }
        if edge.movesRight { maxX += dx }
        if edge.movesTop { maxY += dy }
        if edge.movesBottom { minY += dy }

        // Horizontal limits: pin the side that is not being dragged.
        let draggedLeft = edge.movesLeft
        if maxX - minX < minSize.width {
            if draggedLeft { minX = maxX - minSize.width } else { maxX = minX + minSize.width }
        }
        if let maxSize, maxX - minX > maxSize.width {
            if draggedLeft { minX = maxX - maxSize.width } else { maxX = minX + maxSize.width }
        }

        // Vertical limits.
        let draggedBottom = edge.movesBottom
        if maxY - minY < minSize.height {
            if draggedBottom { minY = maxY - minSize.height } else { maxY = minY + minSize.height }
        }
        if let maxSize, maxY - minY > maxSize.height {
            if draggedBottom { minY = maxY - maxSize.height } else { maxY = minY + maxSize.height }
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
