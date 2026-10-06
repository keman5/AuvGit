import XCTest
import AppKit
import GitCore
@testable import RayGit

@MainActor
final class ComparisonPageRevealTests: XCTestCase {
    func testPatchNavigationUsesChangedLineRatherThanHunkContext() {
        let patch = "@@ -19997,7 +19997,7 @@\n context1\n context2\n context3\n-old\n+ALPHA changed\n context4\n context5\n context6\n@@ -40000,4 +40000,3 @@\n before1\n before2\n before3\n-removed\n"
        let changes = ComparisonPatchOverview.changes(in: DiffParser.parse(patch))
        XCTAssertEqual(changes.map(\.firstLine), [20000, 40003])
        XCTAssertEqual(changes.map(\.lastLine), [20000, 40003])
        XCTAssertEqual(changes.map(\.kind), [.modification, .deletion])
    }
    func testRevealWaitsForMatchingPageAndPublishesOriginalLineStatus() async {
        _ = NSApplication.shared
        let commands = ComparisonEditingCommands()
        var statuses: [ComparisonCursorStatus] = []
        let request = ComparisonRevealRequest(paneID: "stream", firstLine: 19999, number: 20000)
        func model(text: String, firstLine: Int) -> ComparisonEditor {
            ComparisonEditor(columns: [ComparisonEditorColumn(id: "stream", title: "Stream", text: text, isEditable: false, message: nil, firstLine: firstLine)],
                wrapLines: false, showLineNumbers: true, synchronizeScroll: true, search: "", navigation: 0, changeNavigation: 0, onEdit: { _, _ in },
                onCursorChange: { statuses.append($0) }, editingCommands: commands, revealRequest: request)
        }
        let old = model(text: "old page\n", firstLine: 1)
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 300)); split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(old); coordinator.split = split; coordinator.update(old)
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = split; defer { window.close() }
        for _ in 0..<3 { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(statuses.contains { $0.line == 20000 })
        coordinator.update(model(text: "context\nALPHA changed\ntail\n", firstLine: 19999))
        for _ in 0..<5 { split.layoutSubtreeIfNeeded(); try? await Task.sleep(nanoseconds: 1_000_000) }
        let scroll = split.subviews.first?.subviews.compactMap { $0 as? NSScrollView }.first
        let text = scroll?.documentView as? NSTextView
        XCTAssertEqual(text?.selectedRange().location, "context\n".utf16.count)
        XCTAssertEqual(statuses.last?.line, 20000)
        XCTAssertEqual(statuses.last?.column, 1)
    }
}
