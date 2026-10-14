import XCTest
import AppKit
@testable import RayGit

@MainActor
final class ComparisonActionRailTests: XCTestCase {
    func testConnectorExcludesAlignmentPlaceholderSpacing() throws {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = "one\nnext\n"
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 100
        text.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: 4))
        let layout = try XCTUnwrap(text.layoutManager)
        layout.ensureLayout(for: try XCTUnwrap(text.textContainer))
        let rect = try XCTUnwrap(ComparisonActionRail.documentRect(NSRange(location: 0, length: 4), in: text))
        XCTAssertLessThan(rect.height, 40, "The source edge covers its real line, not the alignment spacer")
    }
    func testConnectorJoinsUnequalRangesAndInsertionAnchor() {
        let left = NSRect(x: 0, y: -30, width: 1, height: 80)
        let right = NSRect(x: 0, y: 25, width: 1, height: 0)
        let path = ComparisonActionRail.connectorPath(left: left, right: right, width: 24)
        XCTAssertEqual(path.elementCount, 10)
        XCTAssertEqual(path.bounds.minY, -30)
        XCTAssertEqual(path.bounds.maxY, 50)
        XCTAssertEqual(path.bounds.width, 24)
        var points = [NSPoint](repeating: .zero, count: 3)
        let element = points.withUnsafeMutableBufferPointer { path.element(at: 2, associatedPoints: $0.baseAddress!) }
        XCTAssertEqual(element, .cubicCurveTo)
        XCTAssertEqual(points[2], NSPoint(x: 21, y: 25))
    }

    func testWrappedRangeIncludesAllFragmentsAndEmptyRangeIsAnchor() throws {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 600))
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = String(repeating: "long line ", count: 15) + "\nnext\n"
        let layout = try XCTUnwrap(text.layoutManager)
        layout.ensureLayout(for: try XCTUnwrap(text.textContainer))
        let range = NSRange(location: 0, length: (text.string as NSString).range(of: "\n").location + 1)
        let rect = try XCTUnwrap(ComparisonActionRail.documentRect(range, in: text))
        XCTAssertGreaterThan(rect.height, layout.defaultLineHeight(for: text.font!) * 2)
        let anchor = try XCTUnwrap(ComparisonActionRail.documentRect(NSRange(location: range.length, length: 0), in: text))
        XCTAssertEqual(anchor.height, 0)
        XCTAssertEqual(anchor.minY, rect.maxY, accuracy: 0.01)
    }

    func testInsertionConnectsBeforeAlignmentSpacerIncludingEOF() throws {
        let empty = ComparisonTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 600), textContainer: nil)
        empty.textContainerInset.height = ComparisonEditorMetrics.textInset.height + 100
        XCTAssertEqual(try XCTUnwrap(ComparisonActionRail.documentRect(NSRange(location: 0, length: 0), in: empty)).minY,
            ComparisonEditorMetrics.textInset.height, "A beginning insertion connects before leading alignment padding")
        for value in ["one\nnext\n", "one\n", "one"] {
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.string = value
            let range = (value as NSString).lineRange(for: NSRange(location: 0, length: 0))
            let paragraph = NSMutableParagraphStyle(); paragraph.paragraphSpacing = 100
            text.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: range)
            let layout = try XCTUnwrap(text.layoutManager)
            layout.ensureLayout(for: try XCTUnwrap(text.textContainer))
            let source = try XCTUnwrap(ComparisonActionRail.documentRect(range, in: text))
            let anchor = try XCTUnwrap(ComparisonActionRail.documentRect(NSRange(location: range.length, length: 0), in: text))
            XCTAssertEqual(anchor.minY, source.maxY, accuracy: 0.01, "The empty edge precedes the placeholder, not the following line")
        }
    }

    private final class FlippedRoot: NSView { override var isFlipped: Bool { true } }
    func testArrowStaysBesideSourceBlockInsteadOfMiddleOfResult() throws {
        let root = FlippedRoot(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        defer { window.close() }
        let source = NSTextView(frame: NSRect(x: 0, y: 60, width: 300, height: 300))
        let target = NSTextView(frame: NSRect(x: 400, y: 60, width: 300, height: 300))
        source.string = "our\n"; target.string = "marker\nour\nseparator\nother\nend\n"
        let rail = ComparisonActionRail(frame: NSRect(x: 330, y: 0, width: 56, height: 400))
        for view in [source, target, rail] { root.addSubview(view) }
        for text in [source, target] { text.layoutManager!.ensureLayout(for: text.textContainer!) }
        for right in [true, false] {
            rail.pointsRight = right
            rail.setEntries([.init(text: target, range: NSRange(location: 0, length: target.string.utf16.count),
                sourceText: source, sourceRange: NSRange(location: 0, length: source.string.utf16.count), title: "Apply", action: {})])
            let button = try XCTUnwrap(rail.subviews.first as? NSButton)
            let rect = rail.convert(try XCTUnwrap(ComparisonActionRail.documentRect(NSRange(location: 0, length: source.string.utf16.count), in: source)), from: source)
            XCTAssertEqual(button.frame.midY, rect.midY, accuracy: 0.01)
            XCTAssertEqual(button.frame.minX, right ? 2 : 34)
        }
    }

    func testGutterSignsRenderForEveryEditorFontSizeWithoutTextFallback() throws {
        for size in 9...32 {
            let font = NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
            XCTAssertGreaterThanOrEqual(ComparisonEditorMetrics.signWidth(codeFont: font), CGFloat(size) / 2)
            for addition in [true, false] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
                NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 64, height: 64).fill()
                NSColor.red.setStroke()
                for _ in 0..<50 { ComparisonEditorMetrics.signPath(addition: addition, center: NSPoint(x: 32, y: 32), codeSize: CGFloat(size)).stroke() }
                NSGraphicsContext.restoreGraphicsState()
                let center = try XCTUnwrap(bitmap.colorAt(x: 32, y: 32))
                XCTAssertLessThan(center.greenComponent, 0.2)
                let vertical = try XCTUnwrap(bitmap.colorAt(x: 32, y: 32 - max(2, Int(Double(size) * 0.18))))
                XCTAssertEqual(vertical.greenComponent < 0.8, addition, "Only + has a vertical stroke")
            }
        }
    }

    func testRepeatedNativeRepaintWithUnicodeChangesAndResizing() async throws {
        let original = (0..<180).map { "row \($0) 中文 🙂 العربية" }.joined(separator: "\n") + "\n"
        let changed = original.replacingOccurrences(of: "row 40", with: "changed 40\nadded\nadded again")
        let editor = ComparisonEditor(columns: [
            .init(id: "head", title: "HEAD", text: original, isEditable: false, message: nil),
            .init(id: "worktree", title: "Result", text: changed, isEditable: true, message: nil, preservesUndo: true)
        ], wrapLines: true, showLineNumbers: true, synchronizeScroll: true, search: "", navigation: 0,
            changeNavigation: 0, onEdit: { _, _ in }, scrollsToFirstChangeOnOpen: true)
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 300)); split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(editor); coordinator.split = split; coordinator.update(editor)
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = split
        defer { window.close() }
        split.resetDistribution()
        for index in 0..<24 {
            split.setFrameSize(NSSize(width: index % 2 == 0 ? 900 : 620, height: 300))
            split.layoutSubtreeIfNeeded(); coordinator.alignDisplay()
            coordinator.navigateChange(forward: index % 2 == 0)
            let image = try XCTUnwrap(split.bitmapImageRepForCachingDisplay(in: split.bounds))
            split.cacheDisplay(in: split.bounds, to: image)
            try await Task.sleep(for: .milliseconds(1))
        }
        let texts = split.subviews.flatMap { $0.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTextView } }
        XCTAssertEqual(texts.map(\.string), [original, changed], "Repainting must not alter either file")
    }

    func testAlignmentPlaceholderDoesNotPaintAsChangedOrCurrentLineInGutter() async throws {
        let editor = ComparisonEditor(columns: [
            .init(id: "head", title: "HEAD", text: "old\ntail\n", isEditable: false, message: nil),
            .init(id: "worktree", title: "Result", text: "new\nnew 2\nnew 3\nnew 4\nnew 5\ntail\n", isEditable: true, message: nil, preservesUndo: true)
        ], wrapLines: false, showLineNumbers: true, synchronizeScroll: true, search: "", navigation: 0,
            changeNavigation: 0, onEdit: { _, _ in })
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 300)); split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(editor); coordinator.split = split; coordinator.update(editor)
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = split; window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        split.resetDistribution()
        for _ in 0..<5 { split.layoutSubtreeIfNeeded(); coordinator.alignDisplay(); try await Task.sleep(for: .milliseconds(1)) }
        let pane = try XCTUnwrap(split.subviews.first)
        let text = try XCTUnwrap(pane.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? ComparisonTextView }.first)
        let row = try XCTUnwrap(ComparisonActionRail.documentRect(NSRange(location: 0, length: 4), in: text))
        let gutter = try XCTUnwrap(pane.subviews.first { NSStringFromClass(type(of: $0)).contains("LineGutter") })
        let image = try XCTUnwrap(gutter.bitmapImageRepForCachingDisplay(in: gutter.bounds))
        gutter.cacheDisplay(in: gutter.bounds, to: image)
        let scale = CGFloat(image.pixelsHigh) / gutter.bounds.height
        let normal = try XCTUnwrap(image.colorAt(x: 3, y: Int((row.maxY + 8) * scale))?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(abs(normal.redComponent - normal.greenComponent), 0.03, "Alignment padding must retain its neutral background")
        XCTAssertLessThan(abs(normal.blueComponent - normal.greenComponent), 0.03)
        let line = try XCTUnwrap(image.colorAt(x: 3, y: Int((row.minY + 2) * scale))?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(line.redComponent - line.greenComponent, 0.03, "The real deleted row stays highlighted")
    }
}
