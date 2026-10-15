import XCTest
import AppKit
@testable import AuvGit

final class HistoryColumnLayoutTests: XCTestCase {
    func testDraggingPastMinimumThenReversingUsesOriginalWidth() {
        let origin: CGFloat = 360
        XCTAssertEqual(HistoryColumn.message.resizedWidth(origin: origin, translation: -500), 220)
        XCTAssertEqual(HistoryColumn.message.resizedWidth(origin: origin, translation: -100), 260)
        XCTAssertEqual(HistoryColumn.message.resizedWidth(origin: origin, translation: 0), origin)
    }

    func testColumnMinimumsKeepDateHashAndSubjectReadable() {
        XCTAssertEqual(HistoryColumn.graph.clampedWidth(0), 42)
        XCTAssertEqual(HistoryColumn.message.clampedWidth(0), 220)
        XCTAssertEqual(HistoryColumn.author.clampedWidth(0), 55)
        XCTAssertEqual(HistoryColumn.date.clampedWidth(0), 105)
        XCTAssertEqual(HistoryColumn.hash.clampedWidth(0), 65)
    }

    func testExtremeOrInvalidWidthsRemainUsable() {
        XCTAssertEqual(HistoryColumn.author.clampedWidth(.infinity), 55)
        XCTAssertEqual(HistoryColumn.message.clampedWidth(.nan), 220)
        XCTAssertEqual(HistoryColumn.graph.resizedWidth(origin: 55, translation: 10000), 1600)
    }
    func testCompactDateWidthFitsMeasuredTextAndBoundsLongLabels() {
        XCTAssertEqual(HistoryColumnLayout.compactDateWidth(measuredWidth: 65.2), 66)
        XCTAssertEqual(HistoryColumnLayout.compactDateWidth(measuredWidth: 150), 110)
        XCTAssertEqual(HistoryColumnLayout.compactDateWidth(measuredWidth: 0), 48)
        XCTAssertEqual(HistoryColumnLayout.compactDateWidth(measuredWidth: .nan), 110)
    }

    func testCompactIdentityFitsShortNamesAndCapsLongNamesWithinCombinedBudget() {
        XCTAssertEqual(HistoryColumnLayout.compactAuthorNameWidth(measuredWidth: 24.2, showsAvatar: true), 25)
        for showsAvatar in [false, true] {
            let nameWidth = HistoryColumnLayout.compactAuthorNameWidth(measuredWidth: 1000, showsAvatar: showsAvatar)
            let reserved: CGFloat = showsAvatar ? HistoryColumnLayout.avatarWidth + HistoryColumnLayout.identitySpacing : 0
            XCTAssertLessThanOrEqual(nameWidth + reserved, HistoryColumnLayout.compactIdentityMaximumWidth)
        }
        XCTAssertEqual(HistoryColumnLayout.compactAuthorNameWidth(measuredWidth: -1, showsAvatar: false), 0)
        XCTAssertEqual(HistoryColumnLayout.compactAuthorNameWidth(measuredWidth: .nan, showsAvatar: true), 72)
    }

    func testCommitMessageIndentTracksActiveGraphLanesWithoutMovingLaterColumns() {
        let shallow = HistoryColumnLayout.graphMessageWidths(activeLaneCount: 1, maximumLaneCount: 3, maximumGraphWidth: 54, baseMessageWidth: 360)
        let middle = HistoryColumnLayout.graphMessageWidths(activeLaneCount: 2, maximumLaneCount: 3, maximumGraphWidth: 54, baseMessageWidth: 360)
        let deep = HistoryColumnLayout.graphMessageWidths(activeLaneCount: 3, maximumLaneCount: 3, maximumGraphWidth: 54, baseMessageWidth: 360)

        XCTAssertEqual(shallow.graph, 12)
        XCTAssertEqual(middle.graph, 24)
        XCTAssertEqual(deep.graph, 36)
        XCTAssertLessThan(shallow.graph, middle.graph)
        XCTAssertLessThan(middle.graph, deep.graph)
        XCTAssertEqual(shallow.graph + shallow.message, 414)
        XCTAssertEqual(middle.graph + middle.message, 414)
        XCTAssertEqual(deep.graph + deep.message, 414)
    }

    func testAccessibleGraphGeometryNeverCompressesLanes() {
        XCTAssertEqual(HistoryColumnLayout.graphWidth(laneCount: 1), 12)
        XCTAssertEqual(HistoryColumnLayout.graphWidth(laneCount: 4), 48)
        XCTAssertEqual(HistoryColumnLayout.graphWidth(laneCount: 8), 96)
        XCTAssertEqual(HistoryColumnLayout.rowHeight(compact: true), 22)
        XCTAssertEqual(HistoryColumnLayout.rowHeight(compact: false), 24)
    }

}

@MainActor
final class HistoryNativeResizeTests: XCTestCase {
    func testNativeDraggingResizesLiveWithoutRepeatedReleaseCommitAndRestoresResponder() throws {
        let (window, handle) = makeHandle()
        defer { window.close() }
        let previous = window.firstResponder
        var widths: [CGFloat] = []
        handle.commit = { widths.append($0) }
        handle.mouseDown(with: try event(.leftMouseDown, x: 10, window: window))
        handle.mouseDragged(with: try event(.leftMouseDragged, x: -500, window: window))
        handle.mouseDragged(with: try event(.leftMouseDragged, x: -90, window: window))
        XCTAssertEqual(widths, [220, 260])
        handle.mouseUp(with: try event(.leftMouseUp, x: -90, window: window))
        XCTAssertEqual(widths, [220, 260])
        XCTAssertTrue(window.firstResponder === previous)
        handle.mouseUp(with: try event(.leftMouseUp, x: 100, window: window))
        XCTAssertEqual(widths.count, 2)
    }

    func testNativeCancelRestoresOriginalWidthAndEndsTracking() throws {
        let (window, handle) = makeHandle()
        defer { window.close() }
        var widths: [CGFloat] = []
        handle.commit = { widths.append($0) }
        handle.mouseDown(with: try event(.leftMouseDown, x: 10, window: window))
        handle.mouseDragged(with: try event(.leftMouseDragged, x: 500, window: window))
        XCTAssertEqual(widths, [850])
        handle.cancelOperation(nil)
        handle.mouseUp(with: try event(.leftMouseUp, x: 500, window: window))
        XCTAssertEqual(widths, [850, 360])
        XCTAssertEqual(handle.width, 360)
    }

    private func makeHandle() -> (NSWindow, HistoryResizeHandleView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let handle = HistoryResizeHandleView(frame: NSRect(x: 100, y: 100, width: 9, height: 13))
        handle.column = .message
        handle.width = 360
        window.contentView?.addSubview(handle)
        return (window, handle)
    }

    private func event(_ type: NSEvent.EventType, x: CGFloat, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 100), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}
