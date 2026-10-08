import XCTest
import AppKit
@testable import RayGit

@MainActor
final class DiffPreviewLayoutTests: XCTestCase {
    func testUnwrappedPreviewDoesNotRewriteParagraphsOrRepeatLayout() {
        _ = NSApplication.shared
        let coordinator = DiffTextSurface.Coordinator()
        coordinator.signature = "fixture"
        coordinator.wraps = false
        let paragraph = NSMutableParagraphStyle()
        let document = NSAttributedString(string: String(repeating: "unchanged preview text\n", count: 10_000), attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .paragraphStyle: paragraph])
        var edits = 0
        var observers: [NSObjectProtocol] = []
        for _ in 0..<2 {
            let scroll = ComparisonOverviewScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
            let text = NSTextView(frame: .zero)
            text.isHorizontallyResizable = true
            text.textContainer?.widthTracksTextView = false
            text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.textStorage?.setAttributedString(document)
            scroll.documentView = text
            coordinator.scrolls.append(scroll)
            observers.append(NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: text.textStorage, queue: nil) { _ in edits += 1 })
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        let start = Date()
        coordinator.alignWrappedRows()
        let first = Date().timeIntervalSince(start)
        let repeatStart = Date()
        for _ in 0..<10 { coordinator.alignWrappedRows() }
        print("DIFF_PREVIEW_LAYOUT first=\(first) repeated10=\(Date().timeIntervalSince(repeatStart)) edits=\(edits)")
        XCTAssertEqual(edits, 0, "Unwrapped lines already share their font height; paragraph rewrites must be avoided")
        for scroll in coordinator.scrolls { XCTAssertGreaterThan(scroll.documentView!.frame.height, scroll.contentSize.height) }
        // A preceding wrapped document can leave alignment spacing behind.
        let text = coordinator.scrolls[0].documentView as! NSTextView
        let spaced = NSMutableParagraphStyle(); spaced.paragraphSpacing = 20
        text.textStorage?.addAttribute(.paragraphStyle, value: spaced, range: NSRange(location: 0, length: 23))
        coordinator.lastAlignedSignature = nil
        coordinator.alignWrappedRows()
        XCTAssertEqual((text.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing, 0)
    }
}
