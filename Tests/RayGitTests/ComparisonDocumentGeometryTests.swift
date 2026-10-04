import XCTest
import AppKit
@testable import RayGit

@MainActor
final class ComparisonDocumentGeometryTests: XCTestCase {
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
