import XCTest
import AppKit
@testable import RayGit

@MainActor
final class ComparisonDocumentGeometryTests: XCTestCase {
    func testCurrentLogicalLineBackgroundIncludesEmptyEOFAndWrappedFragments() throws {
        _ = NSApplication.shared
        for value in ["", "line\n", String(repeating: "wrapped text ", count: 30)] {
            let text = ComparisonTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 800), textContainer: nil)
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.string = value
            text.textContainerInset = NSSize(width: 4, height: 3)
            text.textContainer?.containerSize = NSSize(width: 170, height: 10000)
            text.textContainer?.widthTracksTextView = false
            text.setSelectedRange(NSRange(location: value.isEmpty || value.hasSuffix("\n") ? value.utf16.count : 1, length: 0))
            let layout = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
            layout.ensureLayout(for: container)
            let targetY: CGFloat
            if value.isEmpty || value.hasSuffix("\n") {
                targetY = layout.extraLineFragmentRect.minY + text.textContainerInset.height + 2
            } else {
                let lastGlyph = layout.numberOfGlyphs - 1
                let finalFragment = layout.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
                XCTAssertGreaterThan(finalFragment.minY, 0)
                targetY = finalFragment.minY + text.textContainerInset.height + 2
            }
            func render(_ highlight: Bool) throws -> NSColor {
                let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 180, pixelsHigh: 800, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: image))
                NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
                NSGraphicsContext.current = context
                context.cgContext.translateBy(x: 0, y: 800); context.cgContext.scaleBy(x: 1, y: -1)
                NSColor.white.setFill(); text.bounds.fill()
                text.highlightCurrentLine = highlight; text.drawBackground(in: text.bounds)
                return try XCTUnwrap(image.colorAt(x: 170, y: Int(targetY)))
            }
            XCTAssertNotEqual(try render(false), try render(true), "Current line must fill its final wrapped/EOF fragment for \(value.debugDescription)")
        }
    }
    func testLongDocumentsKeepTextAndDecorationsInSameCoordinatesAfterResize() async {
        _ = NSApplication.shared
        let prefix = (0..<160).map { "unchanged \($0)" }.joined(separator: "\n") + "\n"
        let suffix = (0..<80).map { "tail \($0)" }.joined(separator: "\n") + "\n"
        let editor = ComparisonEditor(columns: [
            ComparisonEditorColumn(id: "head", title: "HEAD", text: prefix + "old\n" + suffix, isEditable: false, message: nil),
            ComparisonEditorColumn(id: "worktree", title: "Result", text: prefix + "new\n" + suffix, isEditable: true, message: nil)
        ], wrapLines: true, showLineNumbers: true, synchronizeScroll: true, search: "", navigation: 0,
            changeNavigation: 0, onEdit: { _, _ in }, scrollsToFirstChangeOnOpen: true)
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(editor)
        coordinator.split = split
        coordinator.update(editor)
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = split
        defer { window.close() }
        split.resetDistribution()
        for width in [800.0, 420, 1100, 640] {
            split.setFrameSize(NSSize(width: width, height: 300))
            for _ in 0..<5 {
                split.layoutSubtreeIfNeeded()
                coordinator.alignDisplay()
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            let scrolls = split.subviews.flatMap { $0.subviews.compactMap { $0 as? NSScrollView } }
            XCTAssertEqual(scrolls.count, 2)
            for scroll in scrolls {
                let text = try! XCTUnwrap(scroll.documentView as? NSTextView)
                let layout = try! XCTUnwrap(text.layoutManager)
                layout.ensureLayout(for: text.textContainer!)
                XCTAssertEqual(text.frame.origin, .zero)
                // The gutter and action rail subtract clip.bounds.minY directly.
                // It must also be the document-local y at the visible viewport top.
                let visibleTop = text.convert(scroll.contentView.bounds.origin, from: scroll.contentView)
                XCTAssertEqual(visibleTop.y, scroll.contentView.bounds.minY, accuracy: 0.01)
                let glyph = layout.glyphIndexForCharacter(at: prefix.utf16.count)
                let firstChangeY = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + text.textContainerInset.height
                XCTAssertEqual(scroll.contentView.bounds.minY, firstChangeY - 24, accuracy: 0.1)
                XCTAssertLessThan(scroll.contentView.bounds.maxY, text.bounds.maxY)
            }
        }
    }
}
