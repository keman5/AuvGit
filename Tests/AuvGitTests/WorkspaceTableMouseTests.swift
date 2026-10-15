import AppKit
import SwiftUI
import XCTest
import GitCore
@testable import AuvGit

@MainActor
final class WorkspaceTableMouseTests: XCTestCase {
    private final class Selection: ObservableObject { @Published var paths: Set<String> = ["a"] }
    private struct Fixture: View {
        @ObservedObject var selection: Selection
        @ObservedObject var focus: WorkspaceFileFocus
        let production: Bool
        var treeMode = false
        var repository: GitRepository? = nil
        var files = [GitFile(path: "a", indexStatus: "M", worktreeStatus: " "), GitFile(path: "b", indexStatus: " ", worktreeStatus: "M"), GitFile(path: "c", indexStatus: "?", worktreeStatus: "?")]
        var body: some View {
            if production {
                WorkspaceFilesPane(files: files, selection: $selection.paths, filter: .constant(""), treeMode: .constant(treeMode), isBusy: false, onAction: { _, _ in }, treeContent: { _ in Text("Directory tree") }, repository: repository, fileFocus: focus)
            } else {
                Table(files, selection: $selection.paths) { TableColumn("Name", value: \.path) }
            }
        }
    }
    private func findTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.findTable($0) }.first
    }
    private static var eventNumber = 1_000_000
    private func mouseEvents(at point: NSPoint, in window: NSWindow, flags: NSEvent.ModifierFlags = []) throws -> (down: NSEvent, up: NSEvent) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        Self.eventNumber += 2
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags, timestamp: timestamp, windowNumber: window.windowNumber, context: nil, eventNumber: Self.eventNumber, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: flags, timestamp: max(ProcessInfo.processInfo.systemUptime, timestamp + 0.001), windowNumber: window.windowNumber, context: nil, eventNumber: Self.eventNumber + 1, clickCount: 1, pressure: 0))
        return (down, up)
    }
    private func readyTable(in host: NSView, window: NSWindow) async throws -> NSTableView {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            if let table = findTable(host), table.window === window, table.numberOfRows == 3,
               table.rect(ofRow: 1).height > 0,
               (table as? WorkspaceNativeFilesTable.FileTable).map({ $0.coordinator?.parent.isReady == true }) ?? true,
               table.view(atColumn: 0, row: 1, makeIfNecessary: true) != nil { return table }
            try await Task.sleep(for: .milliseconds(1))
        } while ProcessInfo.processInfo.systemUptime < deadline
        XCTFail("Mouse fixture must publish its three rows and enable native input before the click")
        return try XCTUnwrap(findTable(host))
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
        let table = try await readyTable(in: host, window: window)
        XCTAssertEqual(table.numberOfRows, 3)
        let row = table.rect(ofRow: 1)
        let point = table.convert(NSPoint(x: row.minX + 55, y: row.midY), to: nil)
        let hit = window.contentView?.hitTest(point)
        XCTAssertTrue(try XCTUnwrap(hit).isDescendant(of: table), "Shell and probe backgrounds must route the hit to the table")
        let (down, up) = try mouseEvents(at: point, in: window)
        NSApplication.shared.postEvent(up, atStart: true)
        focus.handle(down)
        try XCTUnwrap(hit).mouseDown(with: down)
        focus.handle(up)
        for _ in 0..<20 {
            if table.selectedRowIndexes == IndexSet(integer: 1), selection.paths == ["b"] { break }
            await Task.yield()
        }
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
    func testFinderMultipleSelectionAndVisibleSelectAll() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let selection = Selection(), focus = WorkspaceFileFocus()
        let host = NSHostingView(rootView: Fixture(selection: selection, focus: focus, production: true))
        window.contentView = host
        let table = try await readyTable(in: host, window: window)
        XCTAssertTrue(table.allowsMultipleSelection)
        XCTAssertTrue(table.allowsEmptySelection)
        func click(_ row: Int, flags: NSEvent.ModifierFlags) async throws {
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: rect.minX + 55, y: rect.midY), to: nil)
            let hit = try XCTUnwrap(window.contentView?.hitTest(point))
            let (down, up) = try mouseEvents(at: point, in: window, flags: flags)
            NSApplication.shared.postEvent(up, atStart: true)
            hit.mouseDown(with: down)
            try await Task.sleep(for: .milliseconds(30))
        }
        try await click(2, flags: .command)
        XCTAssertEqual(selection.paths, ["a", "c"])
        try await click(0, flags: .command)
        XCTAssertEqual(selection.paths, ["c"])
        try await click(0, flags: .shift)
        XCTAssertEqual(selection.paths, ["a", "b", "c"])
        table.selectAll(nil)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(selection.paths, ["a", "b", "c"])
    }
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
            if files.isEmpty { XCTAssertEqual(findTable(host)?.numberOfRows, 0); continue }
            let table = try XCTUnwrap(findTable(host))
            XCTAssertEqual(table.numberOfRows, files.count)
            XCTAssertFalse(table.usesAutomaticRowHeights)
            for row in 0..<table.numberOfRows {
                XCTAssertEqual(table.rect(ofRow: row).height, 22, accuracy: 0.01)
            }
        }
    }
    func testRepositorySwitchKeepsTheNativeTableThroughCacheHitsAndMisses() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let selection = Selection(), focus = WorkspaceFileFocus()
        let roots = ["render-first", "render-second", "render-cold"].map { GitRepository(url: URL(fileURLWithPath: "/" + UUID().uuidString + "/" + $0)) }
        let first = (0..<6001).map { GitFile(path: "file-\($0)", indexStatus: "?", worktreeStatus: "?") }
        let second = (0..<6001).map { GitFile(path: "second-\($0)", indexStatus: "?", worktreeStatus: "?") }
        for (repo, files) in [(roots[0], first), (roots[1], second)] {
            let request = WorkspaceFilePreparation(repository: repo.url.path, files: files, ignoredPaths: [], filter: "",
                filterCase: UserDefaults.standard.string(forKey: "preferences.filterCase") ?? "insensitive", category: .all,
                showHidden: UserDefaults.standard.object(forKey: "workspace.showHiddenFiles") as? Bool ?? true,
                showIgnored: false, sort: [.init(column: .path, ascending: true)])
            _ = try WorkspaceFilePreparationCache.shared.prepare(request)
        }
        let host = NSHostingView(rootView: Fixture(selection: selection, focus: focus, production: true, repository: roots[0], files: first))
        window.contentView = host
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let initialTable = try XCTUnwrap(findTable(host))
        let cold = (0..<6001).map { GitFile(path: "cold-\($0)", indexStatus: "?", worktreeStatus: "?") }
        for (repo, files) in [(roots[1], second), (roots[0], first), (roots[2], cold)] {
            let started = Date()
            var firstUpdatedLayout: TimeInterval?
            selection.paths = Set(files.prefix(5000).map(\.path))
            host.rootView = Fixture(selection: selection, focus: focus, production: true, repository: repo, files: files)
            for _ in 0..<30 {
                host.layoutSubtreeIfNeeded()
                let table = try XCTUnwrap(findTable(host), "A project switch must not replace the table with a loading placeholder")
                XCTAssertTrue(table === initialTable)
                if table.numberOfRows == files.count, !table.selectedRowIndexes.isEmpty, firstUpdatedLayout == nil { firstUpdatedLayout = Date().timeIntervalSince(started) }
                XCTAssertGreaterThan(table.numberOfRows, 0, "Neither cache hits nor misses may expose an intermediate empty table")
                if firstUpdatedLayout != nil { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertEqual(findTable(host)?.numberOfRows, files.count)
            print("Native table switch to \(files.count) rows/5000 selected: \(firstUpdatedLayout ?? -1)s")
            let elapsed = try XCTUnwrap(firstUpdatedLayout)
            if repo.url != roots[2].url { XCTAssertLessThan(elapsed, 0.1, "A prepared repository must render its first target layout within 100ms") }
        }
    }
    func testCachedTreeSwitchDoesNotFlashTheFileTable() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let selection = Selection(), focus = WorkspaceFileFocus()
        let files = [GitFile(path: "file.txt", indexStatus: "?", worktreeStatus: "?")]
        let roots = (0..<2).map { _ in GitRepository(url: URL(fileURLWithPath: "/" + UUID().uuidString)) }
        for repo in roots {
            _ = try WorkspaceFilePreparationCache.shared.prepare(.init(repository: repo.url.path, files: files, ignoredPaths: [], filter: "",
                filterCase: UserDefaults.standard.string(forKey: "preferences.filterCase") ?? "insensitive", category: .all,
                showHidden: UserDefaults.standard.object(forKey: "workspace.showHiddenFiles") as? Bool ?? true,
                showIgnored: false, sort: [.init(column: .path, ascending: true)]))
        }
        let host = NSHostingView(rootView: Fixture(selection: selection, focus: focus, production: true, treeMode: true, repository: roots[0], files: files))
        window.contentView = host
        for repo in roots + roots.reversed() {
            host.rootView = Fixture(selection: selection, focus: focus, production: true, treeMode: true, repository: repo, files: files)
            for _ in 0..<10 {
                host.layoutSubtreeIfNeeded()
                XCTAssertNil(findTable(host), "Cached directory trees must not pass through a file-table frame")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
    func testTreeModeCacheMissNeverRendersTheFileTable() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let selection = Selection(), focus = WorkspaceFileFocus()
        let files = (0..<6001).map { GitFile(path: "file-\($0)", indexStatus: "?", worktreeStatus: "?") }
        let host = NSHostingView(rootView: Fixture(selection: selection, focus: focus, production: true, treeMode: true,
            repository: GitRepository(url: URL(fileURLWithPath: "/" + UUID().uuidString)), files: files))
        window.contentView = host
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            XCTAssertNil(findTable(host), "Cold tree preparation must retain its tree content rather than flash the file table")
            try await Task.sleep(for: .milliseconds(1))
        }
        host.rootView = Fixture(selection: selection, focus: focus, production: true, treeMode: true,
            repository: GitRepository(url: URL(fileURLWithPath: "/" + UUID().uuidString)), files: files)
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            XCTAssertNil(findTable(host))
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func testDefaultColumnsFitWithoutHorizontalOverflow() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: Fixture(selection: Selection(), focus: WorkspaceFileFocus(), production: true,
            files: [GitFile(path: "very/long/directory/" + String(repeating: "filename", count: 30) + ".swift", indexStatus: "A", worktreeStatus: "M")]))
        window.contentView = host
        for width in [550.0, 430.0, 700.0] {
            window.setContentSize(NSSize(width: width, height: 400))
            for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
            let table = try XCTUnwrap(findTable(host))
            let scroll = try XCTUnwrap(table.enclosingScrollView)
            let columns = table.tableColumns.filter { !$0.isHidden }
            XCTAssertEqual(columns.count, 3)
            XCTAssertLessThanOrEqual(table.frame.width, scroll.contentSize.width + 1)
            XCTAssertLessThan(columns[1].minWidth, columns[1].maxWidth)
            XCTAssertLessThan(columns[1].width, 160)
        }
    }
    func testWorkspaceTableMouseSelection() async throws { try await exercise(production: true) }
    func testBorderlessShellWorkspaceTableMouseSelection() async throws { try await exercise(production: true, shell: true) }
}
