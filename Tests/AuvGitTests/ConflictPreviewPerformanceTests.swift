import AppKit
import SwiftUI
import XCTest
import GitCore
@testable import AuvGit

@MainActor
final class ConflictPreviewPerformanceTests: XCTestCase {
    private func textViews(_ view: NSView) -> [NSTextView] {
        if let text = view as? NSTextView { return [text] }
        return view.subviews.flatMap(textViews)
    }

    private func document(_ text: String, identity: String, editable: Bool = false, wraps: Bool = true) -> ComparisonEditor {
        ComparisonEditor(columns: [
            .init(id: "ours", title: "Ours", text: text, isEditable: false, message: nil),
            .init(id: "worktree", title: "Result", text: text + "<<<<<<< ours\nleft\n=======\nright\n>>>>>>> theirs\n", isEditable: editable, message: nil),
            .init(id: "theirs", title: "Theirs", text: text + "right\n", isEditable: false, message: nil)
        ], wrapLines: wraps, showLineNumbers: true, synchronizeScroll: true, search: "", navigation: 0, changeNavigation: 0,
            onEdit: { _, _ in }, languagePath: "docs/status.md", resolver: ComparisonResolverState(),
            scrollsToFirstChangeOnOpen: true, readOnlyDocumentIdentity: identity)
    }

    func testLargeConflictColdLayoutAndDetachedWarmReturn() async throws {
        _ = NSApplication.shared
        ComparisonEditor.Coordinator.clearReadOnlyDocumentCache()
        defer { ComparisonEditor.Coordinator.clearReadOnlyDocumentCache() }
        let sentence = "原生界面与多语言验证保持完整内容、行号、差异颜色以及同步滚动。"
        let source = (0..<586).map { "Row \($0): " + String(repeating: sentence, count: 3) + "\n" }.joined()
        XCTAssertGreaterThan(source.utf8.count, 117_000)
        let editor = document(source, identity: "project/docs/status.md")
        let host = NSHostingView(rootView: AnyView(editor))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 340), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let start = Date()
        window.contentView = host
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        for _ in 0..<3 { try await Task.sleep(for: .milliseconds(1)); host.layoutSubtreeIfNeeded() }
        let cold = Date().timeIntervalSince(start)
        defer { window.close() }
        let original = textViews(host)
        XCTAssertEqual(original.count, 3)
        for (view, column) in zip(original, editor.columns) { XCTAssertEqual(view.string, column.text) }
        let positions = original.map { $0.enclosingScrollView!.contentView.bounds.origin }
        host.rootView = AnyView(Color.clear)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(1))
        XCTAssertTrue(textViews(host).isEmpty)
        let warmStart = Date()
        host.rootView = AnyView(document(source, identity: "project/docs/status.md"))
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(1))
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let warm = Date().timeIntervalSince(warmStart)
        let restored = textViews(host)
        XCTAssertEqual(restored.count, 3)
        for (index, pair) in zip(original, restored).enumerated() {
            XCTAssertTrue(pair.0 === pair.1, "Return must reuse the detached TextKit document")
            XCTAssertEqual(pair.1.enclosingScrollView!.contentView.bounds.origin, positions[index])
        }
        print("CONFLICT_PREVIEW coldMs=\(cold * 1000) warmMs=\(warm * 1000) bytes=\(source.utf8.count)")
        XCTAssertLessThan(cold, 0.5, "First conflict layout must not stall the UI for seconds")
        XCTAssertLessThan(warm, 0.1)
    }

    func testOnlyDetachedUnchangedReadOnlyDocumentsAreReused() {
        _ = NSApplication.shared
        ComparisonEditor.Coordinator.clearReadOnlyDocumentCache()
        defer { ComparisonEditor.Coordinator.clearReadOnlyDocumentCache() }
        let value = document("context\n", identity: "first")
        let first = value.makeCoordinator()
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        split.isVertical = true; first.split = split; first.update(value)
        let parent = NSView(); parent.addSubview(split)
        first.cacheReadOnlyDocument(split)
        XCTAssertNil(ComparisonEditor.Coordinator.takeReadOnlyDocument(for: value), "Mounted documents cannot be shared")
        split.removeFromSuperview()
        XCTAssertNil(ComparisonEditor.Coordinator.takeReadOnlyDocument(for: document("changed\n", identity: "first")))
        XCTAssertNil(ComparisonEditor.Coordinator.takeReadOnlyDocument(for: document("context\n", identity: "other")))
        XCTAssertNil(ComparisonEditor.Coordinator.takeReadOnlyDocument(for: document("context\n", identity: "first", editable: true)))
        XCTAssertTrue(ComparisonEditor.Coordinator.takeReadOnlyDocument(for: value) === first)
        XCTAssertNil(ComparisonEditor.Coordinator.takeReadOnlyDocument(for: value), "An active document has one owner")
        let editable = document("context\n", identity: "edit", editable: true)
        let editingCoordinator = editable.makeCoordinator()
        editingCoordinator.cacheReadOnlyDocument(ComparisonSplitView())
        XCTAssertNil(ComparisonEditor.Coordinator.takeReadOnlyDocument(for: document("context\n", identity: "edit")))
    }

    func testReadOnlyCacheEvictsOldDocumentsAndRejectsOversizedContent() {
        ComparisonEditor.Coordinator.clearReadOnlyDocumentCache()
        defer { ComparisonEditor.Coordinator.clearReadOnlyDocumentCache() }
        for index in 0..<5 {
            let value = document("context\n", identity: "project-\(index)")
            value.makeCoordinator().cacheReadOnlyDocument(ComparisonSplitView())
        }
        XCTAssertNil(ComparisonEditor.Coordinator.takeReadOnlyDocument(for: document("context\n", identity: "project-0")))
        XCTAssertNotNil(ComparisonEditor.Coordinator.takeReadOnlyDocument(for: document("context\n", identity: "project-4")))
        let huge = String(repeating: "x", count: 700_000)
        document(huge, identity: "huge").makeCoordinator().cacheReadOnlyDocument(ComparisonSplitView())
        XCTAssertNil(ComparisonEditor.Coordinator.takeReadOnlyDocument(for: document(huge, identity: "huge")))
    }

    func testCachedConflictPreservesSelectedConflictWithNewToolbarState() async throws {
        _ = NSApplication.shared
        ComparisonEditor.Coordinator.clearReadOnlyDocumentCache()
        defer { ComparisonEditor.Coordinator.clearReadOnlyDocumentCache() }
        let source = "<<<<<<< first\nold\n=======\nnew\n>>>>>>> second\ncontext\n"
        let value = document(source, identity: "selection")
        let host = NSHostingView(rootView: AnyView(value))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(1))
        value.resolver?.select?(1)
        XCTAssertEqual(value.resolver?.selectedBlock, 1)
        host.rootView = AnyView(Color.clear); host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(1))
        let returned = document(source, identity: "selection")
        host.rootView = AnyView(returned); host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(1))
        XCTAssertEqual(returned.resolver?.selectedBlock, 1)
    }
}
