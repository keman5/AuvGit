import XCTest
import AppKit
import SwiftUI
@testable import RayGit
import GitCore

@MainActor
final class NativeCompactHistoryTableTests: XCTestCase {
    private func pane(_ hash: String, selection: Binding<String?> = .constant(nil), action: @escaping (HistoryAction, GitCommit) -> Void = { _, _ in }) -> NativeCompactHistoryTable {
        let commits = [GitCommit(hash: hash, parents: [], author: "Test", date: .distantPast, subject: "Commit", body: "", refs: [])]
        return NativeCompactHistoryTable(commits: commits, graph: CommitGraph(commits: commits),
            styles: HistoryGraphStylePlan(commits: commits, remoteBranchNames: []),
            selection: selection, navigationGeneration: nil, graphWidth: 24, nameWidth: 70, dateWidth: 65,
            showAvatars: false, showNames: true, showRemoteLabels: true, showTagLabels: true,
            isBusy: false, hasMore: false, isLoading: false, onLoadMore: {}, onAction: action)
    }
    func testCellFirstBitmapDrawIncludesSystemAndMonospacedText() throws {
        // Run this test alone to cover cold font resolution, without an AppKit warmup.
        let commit = GitCommit(hash: "123456789abcdef", parents: [], author: "Author", date: .distantPast,
            subject: "A commit with text", body: "", refs: ["HEAD -> main"])
        let view = NativeCompactHistoryTable(commits: [commit], graph: CommitGraph(commits: [commit]),
            styles: HistoryGraphStylePlan(commits: [commit], remoteBranchNames: []),
            selection: .constant(nil), navigationGeneration: nil, graphWidth: 18, nameWidth: 50, dateWidth: 80,
            showAvatars: false, showNames: true, showRemoteLabels: true, showTagLabels: true,
            isBusy: false, hasMore: false, isLoading: false, onLoadMore: {}, onAction: { _, _ in })
        let cell = CompactHistoryCell(frame: NSRect(x: 0, y: 0, width: 650, height: 24))
        cell.configure(parent: view, index: 0)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 650, pixelsHigh: 24,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(cell.bounds)
        cell.draw(cell.bounds)
        XCTAssertEqual(cell.displayedCommitHash, commit.hash)
        // The hash is the last column; alpha there proves the monospace glyphs rendered.
        let hasHashGlyph = (420..<485).contains { x in
            (0..<24).contains { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 }
        }
        XCTAssertTrue(hasHashGlyph)
    }

    func testCoordinatorUsesCurrentRepositoryForSelectionAndContextActions() {
        var selected: String?
        var performed: String?
        let binding = Binding<String?>(get: { selected }, set: { selected = $0 })
        let coordinator = pane("first", selection: binding).makeCoordinator()
        coordinator.parent = pane("second", selection: binding, action: { _, commit in performed = commit.hash })
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("history")))
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.table = table
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        XCTAssertEqual(selected, "second")
        let menu = NSMenu()
        coordinator.menuNeedsUpdate(menu)
        let copy = menu.items.first { ($0.representedObject as? (HistoryAction, GitCommit))?.0 == .copyHash }
        XCTAssertNotNil(copy)
        if let copy { coordinator.performAction(copy) }
        XCTAssertEqual(performed, "second")
    }
    func testBusyMenuDisablesMutationsAndKeepsCopyAvailable() {
        var view = pane("first")
        // Supply the busy state via the memberwise initializer's existing immutable input.
        view = NativeCompactHistoryTable(commits: view.commits, graph: view.graph, styles: view.styles,
            selection: .constant(nil), navigationGeneration: nil, graphWidth: 24, nameWidth: 70, dateWidth: 65,
            showAvatars: false, showNames: true, showRemoteLabels: true, showTagLabels: true,
            isBusy: true, hasMore: false, isLoading: false, onLoadMore: {}, onAction: { _, _ in })
        let coordinator = view.makeCoordinator()
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("history")))
        table.dataSource = coordinator
        coordinator.table = table
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let menu = NSMenu()
        coordinator.menuNeedsUpdate(menu)
        for item in menu.items {
            guard let (action, _) = item.representedObject as? (HistoryAction, GitCommit) else { continue }
            XCTAssertEqual(item.isEnabled, !action.isMutation)
        }
    }
    func testHostedCompactHistoryRetainsTableThroughEmptyRepositoryAndSelectionReload() async throws {
        _ = NSApplication.shared
        var selected: String? = "first"
        let binding = Binding<String?>(get: { selected }, set: { selected = $0 })
        func history(_ hash: String?) -> some View {
            HistoryPane(commits: hash.map { pane($0).commits } ?? [], selection: binding,
                search: .constant(""), isLoading: false, hasMore: false, onLoadMore: {},
                compact: true, showsSearch: false, authorFilter: .constant(""))
                .frame(width: 650, height: 150)
        }
        let host = NSHostingView(rootView: history("first"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 150),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func settle() async throws {
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        try await settle()
        let original = try XCTUnwrap(table(in: host))
        XCTAssertEqual(original.selectedRow, 0)
        XCTAssertEqual((original.view(atColumn: 0, row: 0, makeIfNecessary: true) as? CompactHistoryCell)?.displayedCommitHash, "first")

        selected = nil
        host.rootView = history(nil)
        try await settle()
        XCTAssertTrue(table(in: host) === original)
        XCTAssertEqual(original.numberOfRows, 0)

        selected = "second"
        host.rootView = history("second")
        try await settle()
        XCTAssertTrue(table(in: host) === original)
        XCTAssertEqual(selected, "second")
        XCTAssertEqual(original.selectedRow, 0)
        let cell = try XCTUnwrap(original.view(atColumn: 0, row: 0, makeIfNecessary: true) as? CompactHistoryCell)
        XCTAssertEqual(cell.displayedCommitHash, "second")
        XCTAssertTrue(cell.accessibilityLabel()?.contains("second") == true)

        // Reload populated history too: NSTableView clears its selection during reloadData.
        selected = "third"
        host.rootView = history("third")
        try await settle()
        XCTAssertEqual(selected, "third")
        XCTAssertEqual(original.selectedRow, 0)
        XCTAssertEqual((original.view(atColumn: 0, row: 0, makeIfNecessary: true) as? CompactHistoryCell)?.displayedCommitHash, "third")
    }

}
