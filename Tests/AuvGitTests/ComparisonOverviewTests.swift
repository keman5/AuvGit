import XCTest
import AppKit
@testable import AuvGit

@MainActor
final class ComparisonOverviewTests: XCTestCase {
    func testOversizedTrackDirtyRectCannotEraseNeighboringCode() throws {
        let scroll = ComparisonOverviewScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        scroll.documentView = ComparisonTextView(frame: NSRect(x: 0, y: 0, width: 250, height: 100), textContainer: nil)
        scroll.tile()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSColor.systemPurple.setFill(); NSRect(x: 0, y: 0, width: 300, height: 100).fill()
        NSGraphicsContext.current!.cgContext.translateBy(x: 270, y: 0)
        scroll.drawChangeBackground(in: scroll.overview, rect: NSRect(x: -270, y: 0, width: 300, height: 100))
        NSGraphicsContext.restoreGraphicsState()
        let neighbor = try XCTUnwrap(bitmap.colorAt(x: 100, y: 50)?.usingColorSpace(.deviceRGB))
        let untouched = try XCTUnwrap(bitmap.colorAt(x: 290, y: 50)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(neighbor.greenComponent, 0.8, "The purple code sentinel must not be painted white")
        XCTAssertEqual(neighbor.redComponent, untouched.redComponent, accuracy: 0.01)
        XCTAssertEqual(neighbor.greenComponent, untouched.greenComponent, accuracy: 0.01)
        XCTAssertEqual(neighbor.blueComponent, untouched.blueComponent, accuracy: 0.01)
    }
    func testChangeBandsAndInsertionAnchorsContinueThroughOverviewAndNativeTrack() throws {
        _ = NSApplication.shared
        let scroll = ComparisonOverviewScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 380))
        let text = ComparisonTextView(frame: NSRect(x: 0, y: 0, width: 350, height: 2500), textContainer: nil)
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.highlightCurrentLine = false
        text.string = (0..<120).map { "line \($0)\n" }.joined()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.overview.usesLocalViewport = false
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.close() }
        let source = text.string as NSString
        let offset = source.range(of: "line 10\n").location
        text.layoutManager!.ensureLayout(for: text.textContainer!)
        func pixel(_ view: NSView, x: CGFloat, documentY: CGFloat) throws -> NSColor {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let point = view.convert(NSPoint(x: 0, y: documentY), from: text)
            let y = view.isFlipped ? point.y : view.bounds.maxY - point.y
            let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
            return try XCTUnwrap(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB))
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
            text.lineBackgrounds = [offset: DiffVisualStyle.lineBackground(.systemGreen, dark: appearance == .darkAqua)]
            text.missingLineAnchors = [20: .systemRed]
            for scrollY in [CGFloat(0), 100] {
                scroll.tile()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: scrollY))
                scroll.reflectScrolledClipView(scroll.contentView)
                let changed = try XCTUnwrap(ComparisonActionRail.documentRect(NSRange(location: offset, length: 8), in: text))
                for y in [changed.minY + 3, text.missingChangeY(at: 20) + 0.25] {
                    let expected = try pixel(text, x: 2, documentY: y)
                    for view in [scroll.overview, try XCTUnwrap(scroll.verticalScroller)] {
                        for x in [CGFloat(0.25), view.bounds.width - 0.25] {
                            let actual = try pixel(view, x: x, documentY: y)
                            let sample = "\(type(of: view)) \(appearance) scroll=\(scrollY) x=\(x) documentY=\(y)"
                            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.015, sample)
                            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.015, sample)
                            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.015, sample)
                        }
                    }
                }
            }
        }
    }
    private func configure(_ scroll: NSScrollView, autohides: Bool, documentSize: NSSize) {
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .legacy
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = autohides
        scroll.documentView = NSView(frame: NSRect(origin: .zero, size: documentSize))
    }
    private func assertGeometry(_ scroll: ComparisonOverviewScrollView, reference: NSScrollView,
                                file: StaticString = #filePath, line: UInt = #line) {
        let railWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        XCTAssertEqual(scroll.overview.frame.width, railWidth, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(scroll.contentView.frame.width, reference.contentView.frame.width - railWidth, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(scroll.overview.frame.minX, scroll.contentView.frame.maxX, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(scroll.overview.frame.maxX, reference.contentView.frame.maxX, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(scroll.overview.frame.height, scroll.contentView.frame.height, accuracy: 0.01, file: file, line: line)
        if let nativeScroller = reference.verticalScroller, !nativeScroller.isHidden {
            XCTAssertEqual(scroll.overview.frame.width, nativeScroller.frame.width, accuracy: 0.01, file: file, line: line)
        }
        if let horizontal = scroll.horizontalScroller, let native = reference.horizontalScroller, !horizontal.isHidden, !native.isHidden {
            XCTAssertEqual(horizontal.frame.width, native.frame.width - railWidth, accuracy: 0.01, file: file, line: line)
        }
    }
    func testRepeatedTilingAndResizeReserveExactlyOneNativeScrollerWidth() {
        _ = NSApplication.shared
        let scroll = ComparisonOverviewScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 360))
        let reference = NSScrollView(frame: scroll.frame)
        configure(scroll, autohides: false, documentSize: NSSize(width: 1800, height: 3000))
        configure(reference, autohides: false, documentSize: NSSize(width: 1800, height: 3000))
        for size in [NSSize(width: 600, height: 360), NSSize(width: 900, height: 540), NSSize(width: 480, height: 240), NSSize(width: 600, height: 360)] {
            scroll.setFrameSize(size); reference.setFrameSize(size)
            for _ in 0..<25 {
                reference.tile(); scroll.tile()
                assertGeometry(scroll, reference: reference)
            }
        }
    }
    func testAutohidingScrollerTransitionsDoNotAccumulateRailSpace() {
        _ = NSApplication.shared
        let scroll = ComparisonOverviewScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 360))
        let reference = NSScrollView(frame: scroll.frame)
        configure(scroll, autohides: true, documentSize: NSSize(width: 1800, height: 3000))
        configure(reference, autohides: true, documentSize: NSSize(width: 1800, height: 3000))
        for documentSize in [NSSize(width: 1800, height: 3000), NSSize(width: 50, height: 50), NSSize(width: 1800, height: 3000)] {
            scroll.documentView?.setFrameSize(documentSize); reference.documentView?.setFrameSize(documentSize)
            for _ in 0..<15 { reference.tile(); scroll.tile() }
            assertGeometry(scroll, reference: reference)
        }
    }
    func testNearestMarkerUsesWholeBandAndPreservesChangeIndexesAtEndpoints() {
        let markers = [
            ComparisonOverviewMarker(lower: 0.20, upper: 0.80, kind: .modification, index: 42),
            ComparisonOverviewMarker(lower: 0, upper: 0.03, kind: .addition, index: 9),
            ComparisonOverviewMarker(lower: 0.98, upper: 1, kind: .deletion, index: 103)
        ]
        for point in [-0.1, 0, 0.03, 0.08] { XCTAssertEqual(ComparisonOverviewMarker.nearest(to: point, in: markers)?.index, 9) }
        for point in [0.20, 0.75, 0.80, 0.85] { XCTAssertEqual(ComparisonOverviewMarker.nearest(to: point, in: markers)?.index, 42) }
        for point in [0.95, 0.98, 1, 1.1] { XCTAssertEqual(ComparisonOverviewMarker.nearest(to: point, in: markers)?.index, 103) }
        XCTAssertNil(ComparisonOverviewMarker.nearest(to: 0.5, in: []))
    }
    func testAccessibleChangeButtonsInvokeTheirActualMarkerIndexes() throws {
        let view = ComparisonOverviewView(frame: NSRect(x: 0, y: 0, width: 15, height: 300))
        view.markers = [
            ComparisonOverviewMarker(lower: 0, upper: 0.01, kind: .addition, index: 9),
            ComparisonOverviewMarker(lower: 0.99, upper: 1, kind: .deletion, index: 103)
        ]
        var selected: [Int] = []
        view.onSelect = { selected.append($0) }
        let children = try XCTUnwrap(view.accessibilityChildren()).compactMap { $0 as? NSButton }
        XCTAssertEqual(children.count, 2)
        let nextRead = try XCTUnwrap(view.accessibilityChildren()).compactMap { $0 as? NSButton }
        for (child, retained) in zip(children, nextRead) {
            XCTAssertTrue(child === retained)
            XCTAssertTrue(child.superview === view)
            XCTAssertFalse(child.isHidden)
            XCTAssertTrue(child.isEnabled)
        }
        XCTAssertEqual(view.accessibilityVisibleChildren()?.count, 2)
        view.setFrameSize(NSSize(width: 15, height: 120)); view.layoutSubtreeIfNeeded()
        for child in children { XCTAssertTrue(view.bounds.contains(child.frame)) }
        for child in children { XCTAssertTrue(child.accessibilityPerformPress()) }
        XCTAssertEqual(selected, [9, 103])
    }
    func testFractionNavigationPreservesInteriorAndContinuousDragPositions() {
        let view = ComparisonOverviewView(frame: NSRect(x: 0, y: 0, width: 15, height: 300))
        view.markers = [ComparisonOverviewMarker(lower: 0.2, upper: 0.8, kind: .modification, index: 7)]
        var fractions: [Double] = [], changes: [Int] = []
        view.onNavigate = { fractions.append($0) }; view.onSelect = { changes.append($0) }
        for fraction in [-0.1, 0.35, 0.55, 0.75, 1.2] { view.navigate(to: fraction) }
        XCTAssertEqual(fractions, [0, 0.35, 0.55, 0.75, 1]); XCTAssertTrue(changes.isEmpty)
    }
    func testAlignedGlobalMapPreservesInteriorLinesDeletionAnchorsAndEmptyEOF() {
        let map = ComparisonOverviewLineMap(bands: [
            [0..<2, 0..<2], [2..<6, 2..<5], [6..<6, 5..<8], [6..<7, 8..<9]
        ])
        XCTAssertEqual(map.count, 10)
        XCTAssertEqual(map.lines(at: 0.4), [4, 4])
        XCTAssertEqual(map.lines(at: 0.7), [6, 6])
        XCTAssertEqual(map.lines(at: 1), [6, 8])
        let empty = ComparisonOverviewLineMap(bands: [[0..<0, 0..<1]])
        XCTAssertEqual(empty.lines(at: 1), [0, 0])
        let compressed = ComparisonOverviewLineMap(bands: (0..<10_000).map { [$0..<($0 + 1), $0..<($0 + 1)] })
        XCTAssertEqual(compressed.segments.count, 1)
        XCTAssertEqual(compressed.lines(at: 0.5555), [5555, 5555])
    }

    func testCompactHorizontalSyncMovesCodeInsideStablePaneFrames() {
        let sync = CompactHorizontalSynchronization()
        let left = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let right = NSScrollView(frame: NSRect(x: 301, y: 0, width: 300, height: 200))
        for (index, scroll) in [left, right].enumerated() {
            scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 1800, height: 200))
            scroll.hasHorizontalScroller = true; scroll.tile(); sync.register(scroll, pane: index)
        }
        let frames = [left.frame, right.frame]
        left.contentView.scroll(to: NSPoint(x: 250, y: 0))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: left.contentView)
        XCTAssertEqual(right.contentView.bounds.minX, left.contentView.bounds.minX, accuracy: 0.1)
        XCTAssertEqual([left.frame, right.frame], frames)
        right.contentView.scroll(to: NSPoint(x: 100, y: 0))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: right.contentView)
        XCTAssertEqual(left.contentView.bounds.minX, right.contentView.bounds.minX, accuracy: 0.1)
    }

    func testDiffBoundarySynchronizationClampsElasticBoundsWithoutRepeatedPeerUpdates() {
        let coordinator = DiffTextSurface.Coordinator()
        let left = ComparisonOverviewScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let right = ComparisonOverviewScrollView(frame: left.frame)
        for (scroll, height) in [(left, CGFloat(1000)), (right, CGFloat(700))] {
            let text = FlippedDiffScrollFixture(frame: NSRect(x: 0, y: 0, width: 600, height: height))
            scroll.documentView = text
            scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
            scroll.tile()
            XCTAssertGreaterThan(text.frame.width, scroll.contentSize.width + 50)
            XCTAssertGreaterThan(text.frame.height, scroll.contentSize.height + 100)
        }
        coordinator.scrolls = [left, right]; coordinator.wraps = false
        var notifications = 0
        right.contentView.postsBoundsChangedNotifications = true
        let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: right.contentView, queue: nil) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        for y in [CGFloat(-80), CGFloat(1200)] {
            left.contentView.setBoundsOrigin(NSPoint(x: -40, y: y))
            coordinator.synchronizeScroll(from: left)
            let expected = right.contentView.constrainBoundsRect(NSRect(origin: NSPoint(x: 0,
                y: max(0, y)), size: right.contentView.bounds.size)).origin
            XCTAssertEqual(right.contentView.bounds.minY, expected.y, accuracy: 0.01)
            XCTAssertEqual(right.contentView.bounds.minX, 0, accuracy: 0.01)
            let count = notifications
            for _ in 0..<20 { coordinator.synchronizeScroll(from: left) }
            XCTAssertEqual(notifications, count)
        }
        coordinator.synchronized = false
        right.contentView.scroll(to: NSPoint(x: 0, y: 100))
        left.contentView.setBoundsOrigin(NSPoint(x: 50, y: -40))
        coordinator.synchronizeScroll(from: left)
        XCTAssertEqual(right.contentView.bounds.minY, 100, accuracy: 0.01)
        XCTAssertEqual(right.contentView.bounds.minX, 50, accuracy: 0.01)
    }

}

private final class FlippedDiffScrollFixture: NSView {
    override var isFlipped: Bool { true }
}
