import XCTest
import AppKit
import SwiftUI
@testable import GitCore
@testable import AuvGit

@MainActor
final class DiffPreviewLayoutTests: XCTestCase {
    func testArchiveSummaryFitsShortPreviewAndCanScrollWithoutMovingToolbar() async throws {
        let app = NSApplication.shared
        let wasActive = app.isActive
        let missing = FileRevisionContent(data: nil, text: nil, exists: false, isBinary: false, unavailableReason: nil)
        let archive = FileRevisionContent(data: Data([0x50, 0x4b, 0, 0]), text: nil, exists: true, isBinary: true, unavailableReason: nil, byteCount: 5_000_000)
        let snapshot = FileComparisonSnapshot(path: "design/PhotoSnap-iOS-界面设计.zip", head: missing, index: missing, worktree: archive, base: nil, ours: nil, theirs: nil,
                                              previewTarget: .worktree(path: "design/PhotoSnap-iOS-界面设计.zip", untracked: true))
        let host = NSHostingView(rootView: DiffPane(text: "", title: snapshot.path, isLoading: false, preview: snapshot)
            .background(PreviewBoundsProbe()))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 150), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let bounds = try XCTUnwrap(descendants(host, of: PreviewBoundsView.self).first)
        let previewRect = bounds.convert(bounds.bounds, to: host)
        XCTAssertGreaterThanOrEqual(previewRect.minY, -0.5, "Preview must not paint over the file list")
        XCTAssertLessThanOrEqual(previewRect.maxY, host.bounds.maxY + 0.5, "Summary must fit the split pane")
        let scrolls = descendants(host, of: NSScrollView.self)
        let scroll = try XCTUnwrap(scrolls.first { ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height + 1 }, "Long binary metadata must remain reachable in a short pane")
        let document = try XCTUnwrap(scroll.documentView)
        let originalY = scroll.contentView.bounds.origin.y
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentSize.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, originalY)
        XCTAssertEqual(bounds.convert(bounds.bounds, to: host), previewRect, "Scrolling metadata must leave the comparison toolbar in place")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: originalY))
        scroll.reflectScrolledClipView(scroll.contentView)
        if let path = ProcessInfo.processInfo.environment["AUVGIT_PREVIEW_SNAPSHOT"] {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(app.isActive, wasActive)
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
    }

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

private struct PreviewBoundsProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> PreviewBoundsView { PreviewBoundsView() }
    func updateNSView(_ nsView: PreviewBoundsView, context: Context) {}
}

private final class PreviewBoundsView: NSView {}
