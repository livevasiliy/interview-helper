import CoreGraphics
import XCTest
@testable import InterviewCore

final class WindowResizeTests: XCTestCase {
    private let frame = CGRect(x: 100, y: 200, width: 400, height: 300)   // spans x 100…500, y 200…500
    private let minSize = CGSize(width: 340, height: 220)

    private func resize(_ edge: ResizeEdge, dx: CGFloat = 0, dy: CGFloat = 0, max: CGSize? = nil) -> CGRect {
        WindowResize.resized(frame, edge: edge, dx: dx, dy: dy, minSize: minSize, maxSize: max)
    }

    func testRightAndLeftEdges() {
        XCTAssertEqual(resize(.right, dx: 50), CGRect(x: 100, y: 200, width: 450, height: 300))
        XCTAssertEqual(resize(.left, dx: -40), CGRect(x: 60, y: 200, width: 440, height: 300), "dragging left grows the window leftwards")
        XCTAssertEqual(resize(.left, dx: 30), CGRect(x: 130, y: 200, width: 370, height: 300))
    }

    func testTopAndBottomEdgesUseAppKitsUpwardYAxis() {
        XCTAssertEqual(resize(.top, dy: 20), CGRect(x: 100, y: 200, width: 400, height: 320), "dragging the top edge up grows it")
        XCTAssertEqual(resize(.bottom, dy: -25), CGRect(x: 100, y: 175, width: 400, height: 325), "dragging the bottom edge down grows it")
        XCTAssertEqual(resize(.bottom, dy: 20), CGRect(x: 100, y: 220, width: 400, height: 280))
    }

    func testCornersMoveBothAxes() {
        XCTAssertEqual(resize(.topRight, dx: 10, dy: 15), CGRect(x: 100, y: 200, width: 410, height: 315))
        XCTAssertEqual(resize(.bottomLeft, dx: -10, dy: -15), CGRect(x: 90, y: 185, width: 410, height: 315))
        XCTAssertEqual(resize(.topLeft, dx: -10, dy: 15), CGRect(x: 90, y: 200, width: 410, height: 315))
        XCTAssertEqual(resize(.bottomRight, dx: 10, dy: -15), CGRect(x: 100, y: 185, width: 410, height: 315))
    }

    func testMinimumSizeKeepsTheOppositeEdgeFixed() {
        let leftward = resize(.left, dx: 380)   // would shrink far below the minimum
        XCTAssertEqual(leftward.width, 340)
        XCTAssertEqual(leftward.maxX, 500, "the right edge must not move when the left edge is dragged")

        let rightward = resize(.right, dx: -380)
        XCTAssertEqual(rightward.width, 340)
        XCTAssertEqual(rightward.minX, 100)

        let upward = resize(.bottom, dy: 290)
        XCTAssertEqual(upward.height, 220)
        XCTAssertEqual(upward.maxY, 500, "the top edge must not move when the bottom edge is dragged")

        let downward = resize(.top, dy: -290)
        XCTAssertEqual(downward.height, 220)
        XCTAssertEqual(downward.minY, 200)
    }

    func testMaximumSizeKeepsTheOppositeEdgeFixed() {
        let limit = CGSize(width: 600, height: 500)
        let wide = resize(.left, dx: -1_000, max: limit)
        XCTAssertEqual(wide.width, 600)
        XCTAssertEqual(wide.maxX, 500)
        let tall = resize(.top, dy: 1_000, max: limit)
        XCTAssertEqual(tall.height, 500)
        XCTAssertEqual(tall.minY, 200)
    }

    func testNoMovementLeavesTheFrameUnchanged() {
        for edge in ResizeEdge.allCases {
            XCTAssertEqual(resize(edge), frame, "\(edge)")
        }
    }

    func testCornerHitsMinimumOnBothAxesIndependently() {
        let r = resize(.topRight, dx: -500, dy: -500)
        XCTAssertEqual(r.size, minSize)
        XCTAssertEqual(r.origin, frame.origin, "the bottom-left corner is the fixed point")
    }
}
