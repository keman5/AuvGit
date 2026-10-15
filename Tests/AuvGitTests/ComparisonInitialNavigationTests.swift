import XCTest
import AppKit
@testable import AuvGit

@MainActor
final class ComparisonInitialNavigationTests: XCTestCase {
    private func model(_ left: String, _ right: String, enabled: Bool = true) -> ComparisonEditor {
        ComparisonEditor(columns: [
            ComparisonEditorColumn(id: "head", title: "HEAD", text: left, isEditable: false, message: nil),
            ComparisonEditorColumn(id: "worktree", title: "Result", text: right, isEditable: true, message: nil)
        ], wrapLines: false, showLineNumbers: true, synchronizeScroll: true, search: "", navigation: 0,
            changeNavigation: 0, onEdit: { _, _ in }, scrollsToFirstChangeOnOpen: enabled)
    }
    private func mount(_ model: ComparisonEditor) async -> (ComparisonEditor.Coordinator, NSWindow) {
        _ = NSApplication.shared
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 220)); split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(model)
        coordinator.split = split
        coordinator.update(model)
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = split
        split.resetDistribution()
        // Mirror the real window's asynchronous constraint/alignment passes without
        // showing a test window or depending on its key-window state.
        for _ in 0..<5 {
            split.layoutSubtreeIfNeeded()
            coordinator.alignDisplay()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return (coordinator, window)
    }
    private func lines(_ count: Int) -> String { (0..<count).map { "unchanged \($0)" }.joined(separator: "\n") + "\n" }
    func testInitialPositionSelectsFirstDifferenceRatherThanNextDifference() async {
        let prefix = lines(160)
        let left = prefix + "old first\n" + lines(60) + "old second\n"
        let right = prefix + "new first\n" + lines(60) + "new second\n"
        let (coordinator, window) = await mount(model(left, right)); defer { window.close() }
        XCTAssertTrue(coordinator.didScrollToInitialChange)
        XCTAssertEqual(coordinator.active?.selectedRange().location, prefix.utf16.count)
        XCTAssertGreaterThan(coordinator.active?.enclosingScrollView?.contentView.bounds.minY ?? 0, 100)
        coordinator.update(model(left, right)); coordinator.alignDisplay()
        XCTAssertEqual(coordinator.active?.selectedRange().location, prefix.utf16.count)
    }
    func testChangeAtBeginningDoesNotAdvanceToSecondBlock() async {
        let (coordinator, window) = await mount(model("old\n" + lines(80) + "later old", "new\n" + lines(80) + "later new")); defer { window.close() }
        XCTAssertTrue(coordinator.didScrollToInitialChange)
        XCTAssertEqual(coordinator.active?.selectedRange().location, 0)
    }
    func testNoDifferenceConsumesInitialNavigationAndLaterEditDoesNotJump() async {
        let initial = lines(160)
        let (coordinator, window) = await mount(model(initial, initial)); defer { window.close() }
        XCTAssertTrue(coordinator.didScrollToInitialChange)
        XCTAssertNil(coordinator.active)
        // Refresh a source version after an initially equal comparison. There is now
        // a difference, but initial navigation must remain consumed. A full editable
        // replacement has its own native caret scrolling, so it is not an auto-jump test.
        coordinator.update(model(initial + "new tail", initial)); coordinator.alignDisplay()
        XCTAssertTrue(coordinator.didScrollToInitialChange)
        XCTAssertNil(coordinator.active)
    }
    func testSourceOnlyDeletionAndOptOut() async {
        let prefix = lines(80), left = prefix + "deleted tail"
        let (coordinator, window) = await mount(model(left, prefix)); defer { window.close() }
        XCTAssertTrue(coordinator.didScrollToInitialChange)
        XCTAssertEqual(coordinator.active?.selectedRange().location, prefix.utf16.count)
        let (optOut, otherWindow) = await mount(model(left, prefix, enabled: false)); defer { otherWindow.close() }
        XCTAssertFalse(optOut.didScrollToInitialChange)
        XCTAssertNil(optOut.active)
    }
}
