import AppKit
import SwiftUI
import XCTest
import RayGitLocalization
@testable import GitCore
@testable import RayGit

@MainActor
final class WorkspaceTreeRenderingTests: XCTestCase {
    func testDoubleClickSelectsOnlyClickedFileAndFolderBeforeDefaultAction() {
        let model = Model()
        model.nodes = [WorkspaceFileNode(path: "src", isDirectory: true, children: [
            WorkspaceFileNode(path: "src/a", isDirectory: false, children: []),
            WorkspaceFileNode(path: "src/b", isDirectory: false, children: [])])]
        model.expanded = ["src"]; model.selection = ["src/a", "src/b"]
        var opened: [String] = []
        let parent = WorkspaceTreeTable(rows: WorkspaceTreeRows.flatten(model.nodes, expanded: model.expanded),
            expanded: Binding(get: { model.expanded }, set: { model.expanded = $0 }),
            selection: Binding(get: { model.selection }, set: { model.selection = $0 }),
            repository: GitRepository(url: URL(fileURLWithPath: "/tmp/double-click-tree")), files: [], isBusy: false,
            openFile: { path in XCTAssertEqual(model.selection, [path]); opened.append(path) }, onAction: { _, _ in })
        let coordinator = parent.makeCoordinator()
        let table = WorkspaceTreeTable.TreeTable()
        table.addTableColumn(NSTableColumn(identifier: .init("treeName")))
        table.allowsMultipleSelection = true
        table.dataSource = coordinator; table.delegate = coordinator; coordinator.table = table
        coordinator.update(parent)
        coordinator.activate(row: 2)
        XCTAssertEqual(model.selection, ["src/b"])
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 2))
        XCTAssertEqual(opened, ["src/b"])
        coordinator.activate(row: 0)
        XCTAssertEqual(model.selection, ["src"])
        XCTAssertEqual(model.expanded, [])
        XCTAssertEqual(opened, ["src/b"])
        coordinator.activate(row: -1)
        XCTAssertEqual(model.selection, ["src"])
    }

    func testSelectedTreeCellStartsWithReversedTextAndIcon() throws {
        let file = GitFile(path: "src/file.swift", indexStatus: " ", worktreeStatus: "M")
        let model = Model()
        model.nodes = [WorkspaceFileNode(path: "src", isDirectory: true, children: [WorkspaceFileNode(path: file.path, isDirectory: false, children: [])])]
        model.expanded = ["src"]
        model.selection = [file.path]
        let parent = WorkspaceTreeTable(rows: WorkspaceTreeRows.flatten(model.nodes, expanded: model.expanded),
            expanded: Binding(get: { model.expanded }, set: { model.expanded = $0 }),
            selection: Binding(get: { model.selection }, set: { model.selection = $0 }),
            repository: GitRepository(url: URL(fileURLWithPath: "/tmp/selected-tree-cell")), files: [file], isBusy: false,
            openFile: { _ in }, onAction: { _, _ in })
        let coordinator = parent.makeCoordinator()
        let table = WorkspaceTreeTable.TreeTable()
        table.addTableColumn(NSTableColumn(identifier: .init("treeName")))
        table.dataSource = coordinator; table.delegate = coordinator; coordinator.table = table
        coordinator.update(parent)

        let index = try XCTUnwrap(parent.rows.firstIndex { $0.path == file.path })
        let cell = try XCTUnwrap(coordinator.tableView(table, viewFor: nil, row: index) as? WorkspaceTreeTable.Cell)
        XCTAssertEqual(cell.label.textColor, .white)
        XCTAssertTrue(cell.icon.image === cell.selectedIcon)
    }

    private func tree(_ prefix: String) -> [WorkspaceFileNode] {
        [WorkspaceFileNode(path: prefix, isDirectory: true, children: (0..<6_000).map {
            WorkspaceFileNode(path: "\(prefix)/file\($0)", isDirectory: false, children: [])
        })]
    }
    func testFlattenOnlyIncludesExpandedDescendantsWithStablePathIDs() {
        let nodes = tree("src")
        XCTAssertEqual(WorkspaceTreeRows.flatten(nodes, expanded: []).map(\.path), ["src"])
        let expanded = WorkspaceTreeRows.flatten(nodes, expanded: ["src"])
        XCTAssertEqual(expanded.count, 6_001)
        XCTAssertEqual(expanded.first?.depth, 0)
        XCTAssertEqual(expanded.last?.depth, 1)
        XCTAssertEqual(expanded.last?.id, "src/file5999")
        XCTAssertEqual(Set(expanded.map(\.id)).count, 6_001)
        XCTAssertEqual(WorkspaceTreeRows.flatten(nodes, expanded: []).count, 1)
        let nested = [WorkspaceFileNode(path: "src", isDirectory: true, children: tree("src/nested"))]
        XCTAssertEqual(WorkspaceTreeRows.flatten(nested, expanded: ["src"]).map(\.path), ["src", "src/nested"])
        XCTAssertEqual(WorkspaceTreeRows.flatten(nested, expanded: ["src", "src/nested"]).last?.depth, 2)
    }
    func testLargeCleanSelectionResolvesDirectoriesWithoutScanningEveryChangedFileForEachRow() {
        let selected = Set((0..<5000).map { "clean/file\($0)" }).union(["changed", "empty"])
        let changed = Set((0..<6000).map { "changed/nested/file\($0)" })
        let started = Date()
        let resolved = WorkspaceTreeSelection.resolve(selected, changedPaths: changed)
        XCTAssertEqual(resolved, selected.subtracting(["changed"]).union(changed))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
    }
    private final class Model: ObservableObject {
        @Published var nodes: [WorkspaceFileNode] = []
        @Published var expanded: Set<String> = []
        @Published var selection: Set<String> = []
        @Published var isBusy = false
    }
    private struct Fixture: View {
        @ObservedObject var model: Model
        var body: some View {
            WorkspaceTreeTable(rows: WorkspaceTreeRows.flatten(model.nodes, expanded: model.expanded), expanded: $model.expanded,
                selection: $model.selection, repository: GitRepository(url: URL(fileURLWithPath: "/tmp/tree-render-test")),
                files: [], isBusy: model.isBusy, openFile: { _ in }, onAction: { _, _ in })
        }
    }
    private struct RepositoryFixture: View {
        @ObservedObject var model: Model
        let repository: GitRepository
        var body: some View {
            WorkspaceTree(repository: repository, openFile: { _ in }, isBusy: model.isBusy, onAction: { _, _ in })
        }
    }
    private final class SwitchingModel: ObservableObject {
        @Published var repository: GitRepository
        @Published var selection: Set<String> = []
        @Published var isBusy = false
        var actions: [Set<String>] = []
        init(repository: GitRepository) { self.repository = repository }
    }
    private struct SwitchingRepositoryFixture: View {
        @ObservedObject var model: SwitchingModel
        var body: some View {
            WorkspaceTree(repository: model.repository, openFile: { _ in }, selection: $model.selection,
                isBusy: model.isBusy, onAction: { _, paths in model.actions.append(paths) })
        }
    }
    private func findTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.findTable($0) }.first
    }
    func testNativeTreeDisclosureAndArrowSelectionStayInSync() async throws {
        _ = NSApplication.shared
        let model = Model()
        model.nodes = [WorkspaceFileNode(path: "src", isDirectory: true, children: [WorkspaceFileNode(path: "src/a", isDirectory: false, children: [])])]
        model.expanded = ["src"]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: Fixture(model: model))
        window.contentView = host
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        let table = try XCTUnwrap(findTable(host) as? WorkspaceTreeTable.TreeTable)
        XCTAssertTrue(table.usesAlternatingRowBackgroundColors)
        let coordinator = try XCTUnwrap(table.coordinator)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(model.selection, ["src/a"])
        XCTAssertTrue(coordinator.arrow(123))
        XCTAssertEqual(model.selection, ["src"])
        XCTAssertTrue(coordinator.arrow(123))
        XCTAssertEqual(model.expanded, [])
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        XCTAssertEqual(table.numberOfRows, 1)
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? WorkspaceTreeTable.Cell)
        XCTAssertFalse(cell.disclosure.isHidden)
        cell.disclosure.performClick(nil)
        XCTAssertEqual(model.expanded, ["src"])
    }

    func testMouseTrackingKeepsTreeSelectionDuringStaleBindingUpdate() async throws {
        _ = NSApplication.shared
        let model = Model()
        model.nodes = ["a", "b"].map { WorkspaceFileNode(path: $0, isDirectory: false, children: []) }
        model.selection = ["a"]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: Fixture(model: model))
        window.contentView = host
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        let table = try XCTUnwrap(findTable(host) as? WorkspaceTreeTable.TreeTable)
        let coordinator = try XCTUnwrap(table.coordinator)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 0))
        let generation = coordinator.mouseGeneration
        table.isTrackingMouse = true
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        model.selection = ["a"]
        coordinator.update(coordinator.parent)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1))
        XCTAssertEqual(model.selection, ["a"])
        table.isTrackingMouse = false
        coordinator.finishMouseTracking(generation: generation)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1))
        XCTAssertEqual(model.selection, ["b"])
    }

    func testBusyTreeRefreshesOnlyVisibleDisclosureButtonsAndRejectsClick() async throws {
        _ = NSApplication.shared
        let model = Model()
        model.nodes = tree("src")
        model.expanded = ["src"]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: Fixture(model: model))
        window.contentView = host
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        let table = try XCTUnwrap(findTable(host))
        let available = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? WorkspaceTreeTable.Cell)
        XCTAssertTrue(available.disclosure.isEnabled)
        model.isBusy = true
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        let busy = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? WorkspaceTreeTable.Cell)
        XCTAssertFalse(busy.disclosure.isEnabled)
        busy.disclosure.performClick(nil)
        XCTAssertEqual(model.expanded, ["src"])
        XCTAssertEqual(table.numberOfRows, 6_001)
        XCTAssertNil(table.view(atColumn: 0, row: 6_000, makeIfNecessary: false))
        model.isBusy = false
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        let restored = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? WorkspaceTreeTable.Cell)
        XCTAssertTrue(restored.disclosure.isEnabled)
    }

    func testCachedTreeDefersFreshReloadUntilGitOpeningFinishes() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitProcess.run(at: root, arguments: ["init"])
        try Data().write(to: root.appendingPathComponent("fresh-real.txt"))
        WorkspaceTreeCache.shared.store([WorkspaceFileNode(path: "cached-old.txt", isDirectory: false, children: [])], for: root.path)
        let model = Model()
        model.isBusy = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: RepositoryFixture(model: model, repository: GitRepository(url: root)))
        window.contentView = host
        func visibleName() -> String? {
            guard let table = findTable(host), table.numberOfRows == 1 else { return nil }
            return (table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? WorkspaceTreeTable.Cell)?.label.stringValue
        }
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(visibleName(), "cached-old.txt")
        XCTAssertEqual(WorkspaceTreeCache.shared.nodes(for: root.path)?.first?.path, "cached-old.txt")
        model.isBusy = false
        for _ in 0..<200 {
            host.layoutSubtreeIfNeeded()
            if visibleName() == "fresh-real.txt" { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(visibleName(), "fresh-real.txt")
        XCTAssertEqual(WorkspaceTreeCache.shared.nodes(for: root.path)?.first?.path, "fresh-real.txt")
    }

    func testSameHostRepositorySwitchKeepsTableAndResetsExpansionWithoutStaleRowsOrActions() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        for directory in [a, b] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try await GitProcess.run(at: directory, arguments: ["init"])
        }
        try FileManager.default.createDirectory(at: a.appendingPathComponent("shared"), withIntermediateDirectories: true)
        for path in ["only-a.txt", "shared/a-only.txt", "shared/same.txt"] { try Data().write(to: a.appendingPathComponent(path)) }
        // The different disk content proves a busy target keeps its snapshot without rereading Git.
        try Data().write(to: b.appendingPathComponent("disk-only-b.txt"))
        func cached(_ letter: String) -> [WorkspaceFileNode] {
            [WorkspaceFileNode(path: "only-\(letter).txt", isDirectory: false, children: []),
             WorkspaceFileNode(path: "shared", isDirectory: true, children: [
                WorkspaceFileNode(path: "shared/\(letter)-only.txt", isDirectory: false, children: []),
                WorkspaceFileNode(path: "shared/same.txt", isDirectory: false, children: [])])]
        }
        WorkspaceTreeCache.shared.store(cached("a"), for: a.path)
        WorkspaceTreeCache.shared.store(cached("b"), for: b.path)
        let model = SwitchingModel(repository: GitRepository(url: a))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 250), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: SwitchingRepositoryFixture(model: model))
        window.contentView = host
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(1)) }
        let table = try XCTUnwrap(findTable(host) as? WorkspaceTreeTable.TreeTable)
        let coordinator = try XCTUnwrap(table.coordinator)
        let disclosure = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? WorkspaceTreeTable.Cell)
        disclosure.disclosure.performClick(nil)
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        XCTAssertEqual(table.numberOfRows, 4)
        model.selection = ["shared/same.txt"]
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 3))
        let staleMenu = try XCTUnwrap(coordinator.menu(at: NSPoint(x: 20, y: table.rect(ofRow: 0).midY)))
        let staleCopy = try XCTUnwrap(staleMenu.items.firstIndex { $0.title == fileContextText("copyPath") })
        XCTAssertTrue(staleMenu.items[staleCopy].isEnabled)

        model.isBusy = true
        model.repository = GitRepository(url: b)
        model.selection = ["only-b.txt"]
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(findTable(host) === table)
        XCTAssertEqual(table.numberOfRows, 2, "The target must start collapsed even when both repositories have a shared directory")
        func name(_ row: Int) -> String? { (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? WorkspaceTreeTable.Cell)?.label.stringValue }
        XCTAssertEqual(name(0), "only-b.txt", "The first target layout must use the target snapshot")
        XCTAssertEqual(name(1), "shared")
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 0))
        staleMenu.performActionForItem(at: staleCopy)
        XCTAssertTrue(model.actions.isEmpty)
        for _ in 0..<30 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(name(0), "only-b.txt")
        XCTAssertEqual(model.selection, ["only-b.txt"])
        XCTAssertEqual(WorkspaceTreeCache.shared.nodes(for: b.path)?.first?.path, "only-b.txt")
        let collapsed = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? WorkspaceTreeTable.Cell)
        XCTAssertEqual(collapsed.disclosure.accessibilityValue() as? String, L10n.text("Collapsed", table: "SidebarRefinement"))
        model.isBusy = false
        host.layoutSubtreeIfNeeded()
        staleMenu.performActionForItem(at: staleCopy)
        XCTAssertTrue(model.actions.isEmpty, "A menu created for repository A must not dispatch after repository B becomes ready")
    }

    func testNativeTableSwitchesSixThousandFlatRowsAndCollapsesPromptly() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let model = Model()
        let host = NSHostingView(rootView: Fixture(model: model))
        window.contentView = host
        for (index, prefix) in ["boreal", "atlas", "boreal"].enumerated() {
            let nodes = tree(prefix)
            let selected = Set(nodes[0].children.prefix(5_000).map(\.path))
            let started = Date()
            model.nodes = nodes
            model.expanded = [prefix]
            model.selection = selected
            var firstLayout: TimeInterval?
            for _ in 0..<30 {
                host.layoutSubtreeIfNeeded()
                if let table = findTable(host), table.numberOfRows == 6_001, !table.selectedRowIndexes.isEmpty {
                    firstLayout = Date().timeIntervalSince(started)
                    break
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            let table = try XCTUnwrap(findTable(host))
            XCTAssertEqual(table.numberOfRows, 6_001)
            XCTAssertNil(table.view(atColumn: 0, row: 6_000, makeIfNecessary: false), "Offscreen tree cells must remain uninstantiated")
            XCTAssertFalse(table.selectedRowIndexes.isEmpty)
            XCTAssertEqual(model.selection.count, 5_000)
            XCTAssertEqual(table.rect(ofRow: 0).height, 22, accuracy: 0.01)
            let elapsed = try XCTUnwrap(firstLayout)
            print("Tree first layout \(index == 0 ? "cold" : "warm") 6001 rows/5000 selected: \(elapsed * 1000)ms")
            XCTAssertLessThan(elapsed, 0.1, "The first target layout must stay within 100ms")
            model.expanded = []
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(1)) }
            XCTAssertEqual(table.numberOfRows, 1)
        }
    }
}
