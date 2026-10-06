import XCTest
import AppKit
import SwiftUI
@testable import RayGit

@MainActor
final class ComparisonChromeGeometryTests: XCTestCase {
    func testChangeArrowPairIgnoresInheritedToolbarMinimumWidth() {
        let pair = HStack(spacing: 2) {
            Button {} label: { ComparisonToolbarIcon(name: "chevron.up") }
                .buttonStyle(ComparisonToolbarButtonStyle())
            Button {} label: { ComparisonToolbarIcon(name: "chevron.down") }
                .buttonStyle(ComparisonToolbarButtonStyle())
        }.buttonStyle(ToolbarRowButtonStyle(minimumWidth: 80)).controlSize(.small)
        let host = NSHostingView(rootView: pair)
        XCTAssertEqual(host.fittingSize.width, 46, accuracy: 0.5)
        XCTAssertEqual(host.fittingSize.height, 24, accuracy: 0.5)
    }
    private func model(_ result: String, editable: Bool = true, three: Bool = false) -> ComparisonEditor {
        let source = "head\noriginal\ntail\n"
        var columns = [ComparisonEditorColumn(id: "head", title: "HEAD", text: source, isEditable: false, message: nil)]
        if three { columns.append(ComparisonEditorColumn(id: "index", title: "Index", text: source, isEditable: false, message: nil)) }
        columns.append(ComparisonEditorColumn(id: "worktree", title: "Result", text: result, isEditable: editable, message: nil, preservesUndo: true))
        return ComparisonEditor(columns: columns, wrapLines: true, showLineNumbers: true, synchronizeScroll: true,
            search: "", navigation: 0, changeNavigation: 0, onEdit: { _, _ in })
    }
    private func settle(_ split: ComparisonSplitView, _ coordinator: ComparisonEditor.Coordinator) async {
        for _ in 0..<5 {
            split.layoutSubtreeIfNeeded(); coordinator.alignDisplay()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    func testActionSlotRemainsReservedAfterAcceptingAllChangesAndWhileBusy() async {
        _ = NSApplication.shared
        let initial = model("head\nchanged\ntail\n")
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 300)); split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(initial); coordinator.split = split; coordinator.update(initial)
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = split; defer { window.close() }
        split.resetDistribution(); await settle(split, coordinator)
        let result = split.subviews.last!
        let scroll = result.subviews.compactMap { $0 as? NSScrollView }.first!
        let originalWidth = scroll.contentView.bounds.width
        let rails = result.subviews.compactMap { $0 as? ComparisonActionRail }
        XCTAssertEqual(rails.map { $0.bounds.width }.max(), ComparisonEditorMetrics.actionRailWidth)
        for value in [model("head\noriginal\ntail\n"), model("head\noriginal\ntail\n", editable: false), initial] {
            coordinator.update(value); await settle(split, coordinator)
            XCTAssertEqual(scroll.contentView.bounds.width, originalWidth, accuracy: 0.01)
            XCTAssertEqual(rails.map { $0.bounds.width }.max(), ComparisonEditorMetrics.actionRailWidth)
        }
    }
    func testColumnsEqualizeOnSwitchAndResizeAfterManualDividerDrag() async {
        _ = NSApplication.shared
        let initial = model("head\nchanged\ntail\n")
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 300)); split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(initial); coordinator.split = split; coordinator.update(initial)
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = split; defer { window.close() }
        for three in [false, true, false] {
            coordinator.update(model("head\nchanged\ntail\n", three: three)); split.resetDistribution()
            await settle(split, coordinator)
            let expected = (split.bounds.width - CGFloat(split.subviews.count - 1) * split.dividerThickness) / CGFloat(split.subviews.count)
            for pane in split.subviews { XCTAssertEqual(pane.frame.width, expected, accuracy: 0.5) }
            split.setPosition(140, ofDividerAt: 0)
            split.setFrameSize(NSSize(width: three ? 1100 : 900, height: 300)); await settle(split, coordinator)
            let resized = (split.bounds.width - CGFloat(split.subviews.count - 1) * split.dividerThickness) / CGFloat(split.subviews.count)
            for pane in split.subviews { XCTAssertEqual(pane.frame.width, resized, accuracy: 0.5) }
        }
    }
}
