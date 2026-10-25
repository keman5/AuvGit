import AppKit
import XCTest
@testable import AuvGit

@MainActor
final class ComparisonReviewTests: XCTestCase {
    private func open(_ strings: [String], wraps: Bool = true, conflict: Bool = false) -> (ComparisonEditor.Coordinator, ComparisonSplitView, NSWindow, [ComparisonTextView]) {
        _ = NSApplication.shared
        let model = ComparisonEditor(columns: strings.enumerated().map {
            .init(id: conflict && $0.offset == strings.count - 1 ? "worktree" : "pane\($0.offset)", title: "Pane \($0.offset)", text: $0.element, isEditable: true, message: nil)
        }, wrapLines: wraps, showLineNumbers: true, synchronizeScroll: true, search: "", navigation: 0,
            changeNavigation: 0, onEdit: { _, _ in }, resolver: conflict ? ComparisonResolverState() : nil)
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 1200, height: 400)); split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(model); coordinator.split = split; coordinator.update(model)
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = split
        split.resetDistribution(); split.layoutSubtreeIfNeeded(); coordinator.alignDisplay()
        let texts = split.subviews.compactMap { $0.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? ComparisonTextView }.first }
        return (coordinator, split, window, texts)
    }

    func testClosingEditorReleasesEveryPaneAndDocument() async throws {
        weak var first: ComparisonTextView?, last: ComparisonTextView?, owner: ComparisonEditor.Coordinator?
        autoreleasepool {
            let (coordinator, split, window, texts) = open(["head\nold\n", "head\nnew\n"])
            owner = coordinator; first = texts.first; last = texts.last
            XCTAssertNotNil((texts.first?.enclosingScrollView as? ComparisonOverviewScrollView)?.overview.onNavigate)
            texts.first?.replaceAsUndoableEdit("edited\n")
            window.contentView = nil; window.close()
        }
        // AppKit releases its transient text-layout references on a later run-loop turn.
        for _ in 0..<200 where first != nil || last != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(owner)
        XCTAssertNil(first, "Closing an editor must release its document, including overview navigation callbacks")
        XCTAssertNil(last)
    }

    func testBlockMenuRejectsStaleSourceOrTargetAndFreshActionStillUndoes() throws {
        for changesSource in [true, false] {
            let (coordinator, _, window, texts) = open(["first\nold\nlast\n", "first\nnew\nlast\n"])
            defer { window.close(); withExtendedLifetime(coordinator) {} }
            let target = texts[1]
            let stale = try XCTUnwrap(target.blockMenu?(1).first?.1)
            if changesSource { texts[0].replaceAsUndoableEdit("first\nserver\nlast\n") }
            else { target.replaceAsUndoableEdit("prefix\nfirst\nnew\nlast\n") }
            let draft = target.string
            stale()
            XCTAssertEqual(target.string, draft, "A menu opened against old text must not overwrite the newer document")
            let fresh = try XCTUnwrap(target.blockMenu?(changesSource ? 1 : 2).first?.1)
            fresh()
            XCTAssertNotEqual(target.string, draft)
            target.editingUndoManager.undo()
            XCTAssertEqual(target.string, draft)
        }
    }

    func testConflictMenuRejectsAnOldBlockIndex() throws {
        let block = "<<<<<<< ours\nours\n=======\ntheirs\n>>>>>>> theirs\n"
        let (coordinator, _, window, texts) = open(["ours\n", block + block], conflict: true)
        defer { window.close(); withExtendedLifetime(coordinator) {} }
        let target = texts[1]
        let stale = try XCTUnwrap(target.blockMenu?(0).first?.1)
        coordinator.acceptConflict(.ours, index: 0)
        let draft = target.string
        stale()
        XCTAssertEqual(target.string, draft, "An old menu must not resolve a different conflict after block indices change")
        let fresh = try XCTUnwrap(target.blockMenu?(1).first?.1)
        fresh()
        XCTAssertNotEqual(target.string, draft)
        target.editingUndoManager.undo()
        XCTAssertEqual(target.string, draft)
    }

    func testThreePaneRepeatedScrollKeepsBothAxesAndReusesAlignment() throws {
        let lines = (0..<600).map { "row \($0) " + String(repeating: "content ", count: 20) }
        let source = lines.joined(separator: "\n") + "\n"
        let changed = lines.enumerated().map { $0.offset.isMultiple(of: 15) ? "changed \($0.element)" : $0.element }.joined(separator: "\n") + "\n"
        let (coordinator, split, window, _) = open([source, changed, source], wraps: false)
        defer { window.close() }
        let scrolls = split.subviews.compactMap { $0.subviews.compactMap { $0 as? NSScrollView }.first }
        let first = try XCTUnwrap(scrolls.first), builds = coordinator.alignmentBuildCount
        first.contentView.postsBoundsChangedNotifications = false
        let start = Date()
        for step in 0..<60 {
            let origin = NSPoint(x: step.isMultiple(of: 2) ? 0 : 80, y: CGFloat(step * 80))
            first.contentView.scroll(to: origin)
            coordinator.didScroll(Notification(name: NSView.boundsDidChangeNotification, object: first.contentView))
            for scroll in scrolls { XCTAssertEqual(scroll.contentView.bounds.origin, first.contentView.bounds.origin) }
        }
        print("COMPARISON_SCROLL_60 ms=\(Date().timeIntervalSince(start) * 1000)")
        XCTAssertEqual(coordinator.alignmentBuildCount, builds)
    }

    func testToolbarUpdatesKeepKeyboardFocusedArrowAndApplyLatestSource() throws {
        let (coordinator, split, window, texts) = open(["head\nold\n", "head\nnew\n"])
        defer { window.close(); withExtendedLifetime(coordinator) {} }
        let rails = split.subviews.flatMap { $0.subviews.compactMap { $0 as? ComparisonActionRail } }
        let arrow = try XCTUnwrap(rails.flatMap { $0.subviews.compactMap { $0 as? NSButton } }.first { $0.toolTip?.contains("Pane 0") == true })
        XCTAssertTrue(window.makeFirstResponder(arrow))
        let start = Date()
        for _ in 0..<30 { coordinator.update(coordinator.model) }
        print("COMPARISON_TOOLBAR_30 ms=\(Date().timeIntervalSince(start) * 1000)")
        XCTAssertTrue(window.firstResponder === arrow, "A toolbar refresh must preserve the user's keyboard focus")
        texts[0].replaceAsUndoableEdit("head\nlatest source\n")
        XCTAssertNotNil(arrow.superview)
        arrow.performClick(nil)
        XCTAssertEqual(texts[1].string, texts[0].string, "Cached differences must be invalidated after source edits")
        texts[1].editingUndoManager.undo()
        XCTAssertEqual(texts[1].string, "head\nnew\n")
    }
}
