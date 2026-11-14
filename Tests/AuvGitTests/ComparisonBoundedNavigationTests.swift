import XCTest
import AppKit
@testable import AuvGit

@MainActor
final class ComparisonBoundedNavigationTests: XCTestCase {
    func testSharedTargetsStopAtBothEndsAndRespectCaretBetweenChanges() {
        let ranges = [2..<4, 8..<9, 14..<14]
        XCTAssertEqual(ComparisonChangeTargets(ranges: ranges, position: 0).next, 0)
        XCTAssertNil(ComparisonChangeTargets(ranges: ranges, position: 0).previous)
        XCTAssertNil(ComparisonChangeTargets(ranges: ranges, position: 2).previous)
        XCTAssertEqual(ComparisonChangeTargets(ranges: ranges, position: 2).next, 1)
        XCTAssertEqual(ComparisonChangeTargets(ranges: ranges, position: 6).previous, 0)
        XCTAssertEqual(ComparisonChangeTargets(ranges: ranges, position: 6).next, 1)
        XCTAssertEqual(ComparisonChangeTargets(ranges: ranges, position: 14).previous, 1)
        XCTAssertNil(ComparisonChangeTargets(ranges: ranges, position: 14).next)
        XCTAssertNil(ComparisonChangeTargets(ranges: [], position: 0).next)
        XCTAssertNil(ComparisonChangeTargets(ranges: [], position: 0).previous)
        XCTAssertNil(ComparisonChangeTargets(count: 1, selected: 0).next)
        XCTAssertNil(ComparisonChangeTargets(count: 1, selected: 0).previous)
    }
    func testNativeNavigationNeverWrapsAndRulesResetAvailability() async throws {
        _ = NSApplication.shared
        let commands = ComparisonEditingCommands()
        let before = "a\none\nb\ntwo\nc\nthree\nd\n"
        let after = "a\nONE\nb\nTWO\nc\nTHREE\nd\n"
        var model = ComparisonEditor(columns: [.init(id: "index", title: "Index", text: before, isEditable: false, message: nil), .init(id: "worktree", title: "Working", text: after, isEditable: true, message: nil)], wrapLines: false, showLineNumbers: true, synchronizeScroll: true, search: "", navigation: 0, changeNavigation: 0, onEdit: { _, _ in }, editingCommands: commands, scrollsToFirstChangeOnOpen: true)
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 1000, height: 360)); split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(model); coordinator.split = split; coordinator.update(model)
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = split; defer { window.close() }
        for _ in 0..<5 { split.layoutSubtreeIfNeeded(); coordinator.alignDisplay(); await Task.yield() }
        XCTAssertFalse(commands.canNavigatePreviousChange); XCTAssertTrue(commands.canNavigateNextChange)
        let texts = split.subviews.flatMap { $0.subviews.compactMap { $0 as? NSScrollView }.compactMap { $0.documentView as? NSTextView } }
        let first = try XCTUnwrap(texts.first)
        coordinator.navigateChange(forward: false)
        XCTAssertEqual(first.selectedRange().location, 2)
        coordinator.navigateChange(forward: true); coordinator.navigateChange(forward: true)
        for _ in 0..<3 { await Task.yield() }
        let last = first.selectedRange()
        XCTAssertTrue(commands.canNavigatePreviousChange); XCTAssertFalse(commands.canNavigateNextChange)
        coordinator.navigateChange(forward: true); XCTAssertEqual(first.selectedRange(), last)
        coordinator.navigateChange(forward: false); coordinator.navigateChange(forward: false)
        for _ in 0..<3 { await Task.yield() }
        XCTAssertFalse(commands.canNavigatePreviousChange); XCTAssertTrue(commands.canNavigateNextChange)
        coordinator.navigateChange(forward: false); XCTAssertEqual(first.selectedRange().location, 2)
        model.comparisonRules.ignoreCase = true; coordinator.update(model)
        for _ in 0..<5 { coordinator.alignDisplay(); await Task.yield() }
        XCTAssertFalse(commands.canNavigatePreviousChange); XCTAssertFalse(commands.canNavigateNextChange)
        XCTAssertFalse(window.isVisible)
    }
    func testPatchNavigationUsesActualCaretAndDoesNotWrap() async {
        let coordinator = DiffTextSurface.Coordinator(), commands = ComparisonEditingCommands()
        let text = ReadOnlyDiffTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        text.string = "header\nfirst\ncontext\nsecond\ncontext\nthird\n"
        let scroll = NSScrollView(frame: text.frame); scroll.documentView = text
        coordinator.scrolls = [scroll]; coordinator.changeCommands = commands
        coordinator.hunkRanges = [[NSRange(location: 7, length: 6)], [NSRange(location: 21, length: 7)], [NSRange(location: 36, length: 6)]]
        text.setSelectedRange(NSRange(location: 7, length: 0)); coordinator.highlightCurrentRow(in: text)
        coordinator.scheduleChangeTargets(); for _ in 0..<3 { await Task.yield() }
        XCTAssertFalse(commands.canNavigatePreviousChange); XCTAssertTrue(commands.canNavigateNextChange)
        coordinator.navigateChange(forward: false); XCTAssertEqual(text.selectedRange().location, 7)
        coordinator.navigateChange(forward: true); coordinator.navigateChange(forward: true)
        for _ in 0..<3 { await Task.yield() }
        XCTAssertFalse(commands.canNavigateNextChange)
        coordinator.navigateChange(forward: true); XCTAssertEqual(text.selectedRange().location, 36)
        text.setSelectedRange(NSRange(location: 17, length: 0)); coordinator.highlightCurrentRow(in: text)
        XCTAssertEqual(coordinator.currentChangeTargets().previous, 0); XCTAssertEqual(coordinator.currentChangeTargets().next, 1)
        coordinator.hunkRanges = []; coordinator.scheduleChangeTargets()
        for _ in 0..<3 { await Task.yield() }
        XCTAssertFalse(commands.canNavigatePreviousChange); XCTAssertFalse(commands.canNavigateNextChange)
    }
}
