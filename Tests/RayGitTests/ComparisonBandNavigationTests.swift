import XCTest
import AppKit
@testable import RayGit

@MainActor
final class ComparisonBandNavigationTests: XCTestCase {
    private func contents() -> [String] {
        let original = (1...300).map { "line \($0)" }
        var index = original; index[79] = "index change 80"
        var working = index; working[139] = "working change 140"; working.remove(at: 219)
        working.insert(contentsOf: ["inserted 1", "inserted 2"], at: 260)
        return [original, index, working].map { $0.joined(separator: "\n") + "\n" }
    }
    func testModelIncludesSourceOnlyDeletionAndTargetOnlyInsertion() {
        let groups = ComparisonChangeNavigation(texts: contents()).bands
        XCTAssertEqual(groups.count, 4)
        XCTAssertTrue(groups.contains { !$0[0].isEmpty && $0[2].isEmpty })
        XCTAssertTrue(groups.contains { $0[0].isEmpty && !$0[2].isEmpty })
    }
    func testNavigationSynchronizesEveryPaneWithManualSyncDisabledAndCompactRevealPreservesUndo() async {
        _ = NSApplication.shared
        let strings = contents(), commands = ComparisonEditingCommands()
        let model = ComparisonEditor(columns: [
            ComparisonEditorColumn(id: "head", title: "HEAD", text: strings[0], isEditable: false, message: nil),
            ComparisonEditorColumn(id: "index", title: "Index", text: strings[1], isEditable: false, message: nil),
            ComparisonEditorColumn(id: "worktree", title: "Working", text: strings[2], isEditable: true, message: nil, preservesUndo: true)
        ], wrapLines: true, showLineNumbers: true, synchronizeScroll: false, search: "", navigation: 0, changeNavigation: 0, onEdit: { _, _ in }, editingCommands: commands)
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 1200, height: 300)); split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(model); coordinator.split = split; coordinator.update(model)
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = split; defer { window.close() }
        split.resetDistribution()
        for _ in 0..<5 { split.layoutSubtreeIfNeeded(); coordinator.alignDisplay(); try? await Task.sleep(nanoseconds: 1_000_000) }
        let scrolls = split.subviews.compactMap { $0.subviews.compactMap { $0 as? NSScrollView }.first }
        XCTAssertEqual(scrolls.count, 3)
        var ys: [CGFloat] = []
        for _ in 0..<4 {
            coordinator.navigateChange(forward: true)
            let y = scrolls[0].contentView.bounds.minY; ys.append(y)
            for scroll in scrolls { XCTAssertEqual(scroll.contentView.bounds.minY, y, accuracy: 0.1) }
        }
        XCTAssertEqual(ys, ys.sorted()); XCTAssertEqual(Set(ys).count, 4)
        let text = scrolls[2].documentView as! NSTextView
        XCTAssertNil(commands.replaceSearch(options: ComparisonSearchOptions(query: "working change"), replacement: "edited", all: true))
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 1_000_000) }
        commands.revealLine(paneID: "worktree", number: 140)
        let prefix = text.string.components(separatedBy: "\n").prefix(139).joined(separator: "\n") + "\n"
        XCTAssertEqual(text.selectedRange().location, prefix.utf16.count)
        commands.undo(); XCTAssertEqual(text.string, strings[2])
    }
}
