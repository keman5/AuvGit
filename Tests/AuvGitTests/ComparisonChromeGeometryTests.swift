import XCTest
import AppKit
import SwiftUI
import GitCore
@testable import AuvGit

@MainActor
final class ComparisonChromeGeometryTests: XCTestCase {
    func testMissingFileComparisonPaintsOpaqueBackgroundInBothAppearances() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await GitRepository.initialize(at: root)
        let file = root.appendingPathComponent("package.json")
        try "{\"name\":\"fixture\"}\n".write(to: file, atomically: true, encoding: .utf8)
        ComparePresenter.show(title: "package.json", repository: repository, target: .worktree(path: "package.json", untracked: true))
        let window = try XCTUnwrap(NSApp.windows.first { $0.representedURL == file })
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        func texts(in view: NSView) -> [ComparisonTextView] {
            (view as? ComparisonTextView).map { [$0] } ?? view.subviews.flatMap { texts(in: $0) }
        }
        // Missing revisions now remain editable empty copies instead of a message-only pane.
        for _ in 0..<100 where !texts(in: content).contains(where: { $0.string.isEmpty && $0.isEditable }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(texts(in: content).contains { $0.string.contains("fixture") })
        XCTAssertTrue(texts(in: content).contains { $0.string.isEmpty && $0.isEditable })
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
            window.setContentSize(NSSize(width: 1200, height: 720))
            content.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            let frame = try XCTUnwrap(content.superview)
            let frameBitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: frameBitmap)
            let expected = try XCTUnwrap(frameBitmap.colorAt(x: frameBitmap.pixelsWide / 4, y: 8)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(expected.redComponent, expected.greenComponent, accuracy: 0.01)
            XCTAssertEqual(expected.greenComponent, expected.blueComponent, accuracy: 0.01)
            XCTAssertEqual(expected.redComponent < 0.5, appearance == .darkAqua)
            for x in [frameBitmap.pixelsWide / 4, frameBitmap.pixelsWide * 3 / 4] {
                let color = try XCTUnwrap(frameBitmap.colorAt(x: x, y: 8)?.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(color.alphaComponent, 0.99, "The native title bar must hide windows underneath")
                XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 0.03)
                XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 0.03)
                XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 0.03)
            }
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            for y in [8, bitmap.pixelsHigh - 9] {
                for x in [bitmap.pixelsWide / 4, bitmap.pixelsWide * 3 / 4] {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
                    XCTAssertGreaterThan(color.alphaComponent, 0.99, "Navigation and status bars must hide windows underneath")
                }
            }
            for y in [bitmap.pixelsHigh / 6, bitmap.pixelsHigh / 2, bitmap.pixelsHigh * 5 / 6] {
                let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 4, y: y)?.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(color.alphaComponent, 0.99, "The entire missing-file pane must hide windows underneath")
                XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 0.03)
                XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 0.03)
                XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 0.03)
            }
            XCTAssertEqual(content.superview?.layer?.cornerRadius, 12)
            XCTAssertFalse(window.isOpaque, "The rounded outer corners must stay transparent")
        }
    }
    func testMissingLineAtDocumentEdgesMatchesFirstAddedLine() async throws {
        _ = NSApplication.shared
        for source in ["", "head\n", "head", "🙂\n"] {
            let target = source.isEmpty ? "one\ntwo\n" : source.trimmingCharacters(in: .newlines) + "\none\ntwo\n"
            let editor = ComparisonEditor(columns: [
                .init(id: "head", title: "HEAD", text: source, isEditable: false, message: nil),
                .init(id: "worktree", title: "Worktree", text: target, isEditable: true, message: nil)
            ], wrapLines: true, showLineNumbers: true, synchronizeScroll: true, search: "", navigation: 0, changeNavigation: 0, onEdit: { _, _ in })
            let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 300)); split.isVertical = true
            let coordinator = ComparisonEditor.Coordinator(editor); coordinator.split = split; coordinator.update(editor)
            let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = split; defer { window.close() }
            split.resetDistribution(); await settle(split, coordinator)
            let texts = split.subviews.compactMap { $0.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? ComparisonTextView }
            let left = try XCTUnwrap(texts.first), right = try XCTUnwrap(texts.last)
            let glyph = right.layoutManager!.glyphIndexForCharacter(at: (target as NSString).range(of: "one").location)
            let y = right.layoutManager!.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + right.textContainerInset.height
            XCTAssertEqual(left.missingChangeY(at: source.isEmpty ? 0 : 1), y, accuracy: 0.5)
        }
    }
    func testRapidEdgeScrollAndRetileRemainSynchronized() async throws {
        _ = NSApplication.shared
        let content = (0..<500).map { "line \($0)" }.joined(separator: "\n")
        let editor = ComparisonEditor(columns: [
            .init(id: "head", title: "HEAD", text: content, isEditable: false, message: nil),
            .init(id: "worktree", title: "Worktree", text: content, isEditable: true, message: nil)
        ], wrapLines: true, showLineNumbers: true, synchronizeScroll: true, search: "", navigation: 0, changeNavigation: 0, onEdit: { _, _ in })
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 300)); split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(editor); coordinator.split = split; coordinator.update(editor)
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = split; defer { window.close() }
        split.resetDistribution(); await settle(split, coordinator)
        let scrolls = split.subviews.compactMap { $0.subviews.compactMap { $0 as? ComparisonOverviewScrollView }.first }
        XCTAssertEqual(scrolls.count, 2)
        for step in 0..<80 {
            let source = scrolls[step % 2]
            let y = step % 4 < 2 ? 0 : max(0, source.documentView!.bounds.height - source.contentSize.height)
            source.contentView.scroll(to: NSPoint(x: 0, y: y))
            source.tile(); coordinator.alignDisplay()
            for scroll in scrolls {
                XCTAssertEqual(scroll.contentView.bounds.minY, y, accuracy: 0.5)
                XCTAssertEqual(scroll.verticalScrollElasticity, .none)
                XCTAssertFalse(scroll.autohidesScrollers)
            }
        }
    }
    func testTargetOnlyAdditionUsesMissingLineAndUndoableDeleteButton() async throws {
        _ = NSApplication.shared
        let content = "head\noriginal\nnew 1\nnew 2\ntail\n"
        let editor = model(content)
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 300)); split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(editor); coordinator.split = split; coordinator.update(editor)
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = split; defer { window.close() }
        split.resetDistribution(); await settle(split, coordinator)
        let texts = split.subviews.compactMap { $0.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? ComparisonTextView }
        XCTAssertEqual(texts.count, 2)
        let left = try XCTUnwrap(texts.first), right = try XCTUnwrap(texts.last)
        XCTAssertEqual(left.string, "head\noriginal\ntail\n")
        XCTAssertEqual(left.missingLineAnchors[2], .systemGreen)
        XCTAssertLessThan(left.missingChangeY(at: 2), right.textContainerInset.height + right.layoutManager!.usedRect(for: right.textContainer!).maxY)
        let rails = split.subviews.last!.subviews.compactMap { $0 as? ComparisonActionRail }
        let button = try XCTUnwrap(rails.flatMap { $0.subviews.compactMap { $0 as? NSButton } }.first)
        XCTAssertEqual(button.title, ""); XCTAssertNotNil(button.image)
        XCTAssertEqual(button.contentTintColor, DiffVisualStyle.actionColor)
        button.performClick(nil)
        XCTAssertEqual(right.string, left.string)
        right.editingUndoManager.undo()
        XCTAssertEqual(right.string, content)
    }
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
