import AppKit
import SwiftUI
import XCTest
import GitCore
@testable import AuvGit

@MainActor
final class ListRangeSelectionTests: XCTestCase {
    private func click(_ row: Int, in table: NSTableView, flags: NSEvent.ModifierFlags = []) throws {
        let window = try XCTUnwrap(table.window)
        let point = table.convert(NSPoint(x: 100, y: table.rect(ofRow: row).midY), to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: flags, timestamp: time, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: flags, timestamp: time + 0.001, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 0))
        NSApplication.shared.postEvent(up, atStart: true)
        table.mouseDown(with: down)
    }
    func testShiftRangeCanGrowShrinkReverseAndToggleWithCommand() {
        var state = ListSelectionState<String>()
        let rows = ["a", "b", "c", "d", "e"]
        state.click("b", shift: false, command: false, orderedIDs: rows)
        state.click("e", shift: true, command: false, orderedIDs: rows)
        XCTAssertEqual(state.ids, ["b", "c", "d", "e"])
        state.click("c", shift: true, command: false, orderedIDs: rows)
        XCTAssertEqual(state.ids, ["b", "c"])
        state.click("a", shift: true, command: false, orderedIDs: rows)
        XCTAssertEqual(state.ids, ["a", "b"])
        state.click("e", shift: false, command: true, orderedIDs: rows)
        XCTAssertEqual(state.ids, ["a", "b", "e"])
        state.click("b", shift: false, command: true, orderedIDs: rows)
        XCTAssertEqual(state.ids, ["a", "e"])
        state.click("d", shift: false, command: false, orderedIDs: rows)
        XCTAssertEqual(state.ids, ["d"])
    }

    func testDetailBindingPreservesRangeOnRefreshSortAndExternalNavigation() async throws {
        var state = ListSelectionState<String>()
        var primary: String? = "a"
        let storage = Binding(get: { state }, set: { state = $0 })
        let detail = Binding(get: { primary }, set: { primary = $0 })
        let selection = ListSelectionState.binding(storage, primary: detail, orderedIDs: ["a", "b", "c", "d"])
        selection.wrappedValue = ["a", "b", "c"]
        XCTAssertEqual(selection.wrappedValue, ["a", "b", "c"], "The range stays visible while detail publication is deferred")
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(primary, "c")
        XCTAssertEqual(selection.wrappedValue, ["a", "b", "c"])
        let sorted = ListSelectionState.binding(storage, primary: detail, orderedIDs: ["d", "c", "b", "a"])
        XCTAssertEqual(sorted.wrappedValue, ["a", "b", "c"])
        primary = "d"
        XCTAssertEqual(selection.wrappedValue, ["d"])
        primary = nil
        XCTAssertTrue(selection.wrappedValue.isEmpty)
    }

    func testNativeStashShiftClickSelectsTheRangeWithoutOpeningAWindow() throws {
        _ = NSApplication.shared
        let view = NativeBranchTable(branches: [], stashes: (0..<4).map {
            GitStash(ref: "stash@{\($0)}", subject: "stash \($0)", hash: "hash\($0)")
        }, repositoryPath: "/stash-fixture", currentBranch: "main", isBusy: false,
            localExpanded: .constant(true), stashesExpanded: .constant(true), selection: .constant(nil),
            onAction: { _, _ in XCTFail("Range selection is not an activation") }, onRenameStash: { _ in }, onShortcut: { _ in false })
        let coordinator = view.makeCoordinator()
        let table = NativeBranchTable.Table(frame: NSRect(x: 0, y: 0, width: 350, height: 240))
        table.coordinator = coordinator
        table.headerView = nil; table.rowHeight = 24; table.intercellSpacing = .zero
        table.allowsMultipleSelection = true
        table.addTableColumn(NSTableColumn(identifier: .init("branch")))
        table.dataSource = coordinator; table.delegate = coordinator; coordinator.table = table
        let window = NSWindow(contentRect: table.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: table.frame)
        scroll.documentView = table; window.contentView = scroll
        coordinator.update(view)
        let rows = coordinator.rows.indices.filter { coordinator.rows[$0].id.hasPrefix("stash:") }
        XCTAssertFalse(window.isVisible)
        try click(rows[0], in: table)
        try click(rows[3], in: table, flags: .shift)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(rows))
        try click(rows[1], in: table, flags: .shift)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(rows.prefix(2)))
        try click(rows[3], in: table, flags: .command)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet([rows[0], rows[1], rows[3]]))
        XCTAssertFalse(window.isVisible)
    }

    func testDeferredDetailCannotOverrideNewerClicksOrNavigation() async throws {
        var state = ListSelectionState<String>()
        var primary: String? = "a"
        let selection = ListSelectionState.binding(Binding(get: { state }, set: { state = $0 }),
            primary: Binding(get: { primary }, set: { primary = $0 }), orderedIDs: ["a", "b", "c", "d"])
        selection.wrappedValue = ["a", "b"]
        selection.wrappedValue = ["c"]
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(primary, "c")
        selection.wrappedValue = []
        state = .init()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(primary, "c", "An old queued deselection cannot clear a new scope")
        selection.wrappedValue = ["a", "b"]
        primary = "d"
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(primary, "d", "Explicit navigation wins over queued preview updates")
        XCTAssertEqual(selection.wrappedValue, ["d"])
    }

    func testCompactAndExpandedHistoryRetainMultiSelectionAfterDetailUpdates() async throws {
        _ = NSApplication.shared
        final class Detail: ObservableObject { @Published var hash: String? = "a" }
        struct Fixture: View {
            @ObservedObject var detail: Detail
            let compact: Bool
            let commits: [GitCommit]
            var body: some View {
                HistoryPane(commits: commits, selection: $detail.hash, search: .constant(""),
                    isLoading: false, hasMore: false, onLoadMore: {}, compact: compact,
                    showsSearch: false, showsDetails: false, authorFilter: .constant(""))
                    .frame(width: 900, height: 240)
            }
        }
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { findTable($0) }.first
        }
        let commits = ["a", "b", "c", "d"].map {
            GitCommit(hash: $0, parents: [], author: "Test", date: .distantPast, subject: $0, body: "", refs: [])
        }
        for compact in [true, false] {
            let detail = Detail()
            let host = NSHostingView(rootView: Fixture(detail: detail, compact: compact, commits: commits))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 240),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.close() }
            for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
            let table = try XCTUnwrap(findTable(host))
            XCTAssertTrue(table.allowsMultipleSelection)
            try click(0, in: table)
            try click(2, in: table, flags: .shift)
            for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(detail.hash, "c", "The range endpoint drives the detail pane")
            XCTAssertEqual(table.selectedRowIndexes, IndexSet(integersIn: 0...2), "Detail redraw cannot collapse the selection")
            detail.hash = "d"
            for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 3), "Explicit navigation replaces a range")
            XCTAssertFalse(window.isVisible)
        }
    }

    func testStashRangeSurvivesRefreshAndResetsAcrossRepositories() throws {
        var primary: String?
        func pane(_ path: String) -> NativeBranchTable {
            NativeBranchTable(branches: [], stashes: (0..<4).map {
                GitStash(ref: "stash@{\($0)}", subject: "stash \($0)", hash: "hash\($0)")
            }, repositoryPath: path, currentBranch: "main", isBusy: false,
                localExpanded: .constant(true), stashesExpanded: .constant(true),
                selection: Binding(get: { primary }, set: { primary = $0 }),
                onAction: { _, _ in XCTFail("Selection must not apply or drop a stash") },
                onRenameStash: { _ in XCTFail("Selection must not rename a stash") }, onShortcut: { _ in false })
        }
        let view = pane("/first")
        let coordinator = view.makeCoordinator()
        let table = NativeBranchTable.Table()
        table.addTableColumn(NSTableColumn(identifier: .init("branch")))
        table.allowsMultipleSelection = true
        table.dataSource = coordinator; table.delegate = coordinator; coordinator.table = table
        coordinator.update(view)
        let stashRows = IndexSet(coordinator.rows.indices.filter { coordinator.rows[$0].id.hasPrefix("stash:") })
        table.selectRowIndexes(stashRows, byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        coordinator.update(pane("/first"))
        XCTAssertEqual(table.selectedRowIndexes, stashRows, "A refresh must retain the whole stash range")
        coordinator.update(pane("/second"))
        XCTAssertTrue(table.selectedRowIndexes.isEmpty, "Stash indices must not leak into another repository")
    }
}
