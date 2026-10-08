import AppKit
import SwiftUI
import XCTest
import GitCore
@testable import RayGit

@MainActor
final class WorkspaceTableMouseTests: XCTestCase {
    private final class Selection: ObservableObject { @Published var paths: Set<String> = ["a"] }
    private struct Fixture: View {
        @ObservedObject var selection: Selection
        @ObservedObject var focus: WorkspaceFileFocus
        let production: Bool
        var files = [GitFile(path: "a", indexStatus: "M", worktreeStatus: " "), GitFile(path: "b", indexStatus: " ", worktreeStatus: "M"), GitFile(path: "c", indexStatus: "?", worktreeStatus: "?")]
        var body: some View {
            if production {
                WorkspaceFilesPane(files: files, selection: $selection.paths, filter: .constant(""), treeMode: .constant(false), isBusy: false, onAction: { _, _ in }, treeContent: { _ in EmptyView() }, fileFocus: focus)
            } else {
                Table(files, selection: $selection.paths) { TableColumn("Name", value: \.path) }
            }
        }
    }
    private func findTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.findTable($0) }.first
    }
    private func exercise(production: Bool, shell: Bool = false) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let selection = Selection()
        let focus = WorkspaceFileFocus()
        let host = NSHostingView(rootView: Fixture(selection: selection, focus: focus, production: production))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        window.contentView = shell ? EightPointFrameView(content: host) : host
        for _ in 0..<20 { window.contentView?.layoutSubtreeIfNeeded(); host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
        let table = try XCTUnwrap(findTable(host))
        XCTAssertEqual(table.numberOfRows, 3)
        let row = table.rect(ofRow: 1)
        let point = table.convert(NSPoint(x: row.minX + 55, y: row.midY), to: nil)
        let hit = window.contentView?.hitTest(point)
        XCTAssertTrue(try XCTUnwrap(hit).isDescendant(of: table), "Shell and probe backgrounds must route the hit to the table")
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 1.1, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApplication.shared.postEvent(up, atStart: true)
        focus.handle(down)
        try XCTUnwrap(hit).mouseDown(with: down)
        focus.handle(up)
        for _ in 0..<5 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1))
        XCTAssertEqual(selection.paths, ["b"])
        if production {
            XCTAssertTrue(focus.hasFileFocus)
            let files = Fixture(selection: selection, focus: focus, production: true).files
            let toolbarSelection = focus.hasFileFocus ? selection.paths : []
            XCTAssertEqual(WorkspaceFileActionTargets.paths(for: .stage, files: files, selection: toolbarSelection), ["b"], "A focused-row toolbar stage must not include other eligible file c")
        }
    }
    func testBaselineTableMouseSelection() async throws { try await exercise(production: false) }
    func testWorkspaceRowHeightRemainsCompactAcrossFileListReplacement() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let selection = Selection()
        let focus = WorkspaceFileFocus()
        let host = NSHostingView(rootView: Fixture(selection: selection, focus: focus, production: true))
        window.contentView = host
        let projects: [[GitFile]] = [host.rootView.files, [GitFile(path: "next.txt", indexStatus: "?", worktreeStatus: "?")], [], host.rootView.files]
        for files in projects {
            host.rootView = Fixture(selection: selection, focus: focus, production: true, files: files)
            for _ in 0..<20 {
                host.layoutSubtreeIfNeeded()
                if !files.isEmpty, let table = findTable(host), table.numberOfRows == files.count {
                    for row in 0..<table.numberOfRows {
                        XCTAssertEqual(table.rect(ofRow: row).height, 22, accuracy: 0.01, "The first populated layout must already use compact rows")
                    }
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            if files.isEmpty { XCTAssertNil(findTable(host)); continue }
            let table = try XCTUnwrap(findTable(host))
            XCTAssertEqual(table.numberOfRows, files.count)
            XCTAssertFalse(table.usesAutomaticRowHeights)
            for row in 0..<table.numberOfRows {
                XCTAssertEqual(table.rect(ofRow: row).height, 22, accuracy: 0.01)
            }
        }
    }
    func testWorkspaceTableMouseSelection() async throws { try await exercise(production: true) }
    func testBorderlessShellWorkspaceTableMouseSelection() async throws { try await exercise(production: true, shell: true) }
}
