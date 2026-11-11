import AppKit
import SwiftUI
import XCTest
import GitCore
import AuvGitLocalization
@testable import AuvGit

@MainActor
final class WorkspaceNativeFilesTableTests: XCTestCase {
    func testReturningFromComparisonRestoresDiscardedNativeRowsWithoutGitChanges() throws {
        _ = NSApplication.shared
        let parent = WorkspaceNativeFilesTable(rows: ["a.swift", "b.swift"].map { WorkspaceFileRow(path: $0, file: nil) },
            files: [], repository: nil, selection: .constant(["b.swift"]), isBusy: false,
            sortOrder: .constant([]), onAction: { _, _ in }, onCompare: { _ in })
        let coordinator = parent.makeCoordinator()
        let table = WorkspaceNativeFilesTable.FileTable()
        table.coordinator = coordinator
        table.addTableColumn(NSTableColumn(identifier: .init("filename")))
        table.dataSource = coordinator; table.delegate = coordinator
        coordinator.table = table; coordinator.update(parent)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 250))
        scroll.documentView = table
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.close() }
        // Model AppKit discarding its cached row count while the hosting tree
        // and coordinator still retain the same prepared file snapshot.
        table.dataSource = nil; table.reloadData()
        XCTAssertEqual(table.numberOfRows, 0)
        table.dataSource = coordinator
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1))
        XCTAssertGreaterThanOrEqual(table.frame.height, table.rect(ofRow: 1).maxY)
        XCTAssertFalse(window.isVisible)
    }

    func testRecreatedTableLoadsUnchangedSnapshotAndRestoresSelection() {
        let parent = WorkspaceNativeFilesTable(rows: ["a.swift", "b.swift"].map { WorkspaceFileRow(path: $0, file: nil) },
            files: [], repository: nil, selection: .constant(["b.swift"]), isBusy: false,
            sortOrder: .constant([]), onAction: { _, _ in }, onCompare: { _ in })
        let coordinator = parent.makeCoordinator()
        func table() -> WorkspaceNativeFilesTable.FileTable {
            let table = WorkspaceNativeFilesTable.FileTable()
            table.addTableColumn(NSTableColumn(identifier: .init("filename")))
            table.dataSource = coordinator; table.delegate = coordinator
            return table
        }
        let original = table()
        coordinator.table = original; coordinator.update(parent)
        XCTAssertEqual(original.numberOfRows, 2)
        let replacement = table()
        coordinator.table = replacement; coordinator.update(parent)
        XCTAssertEqual(replacement.numberOfRows, 2)
        XCTAssertEqual(replacement.selectedRowIndexes, IndexSet(integer: 1))
    }

    func testFileNameTooltipOmitsDirectoriesAndPathTooltipIsRepositoryRelative() throws {
        let root = URL(fileURLWithPath: "/tmp/Tooltip Repository")
        let path = "Deep Folder/完整的文件名.swift"
        let parent = WorkspaceNativeFilesTable(rows: [.init(path: path, file: nil)], files: [], repository: GitRepository(url: root),
            selection: .constant([]), isBusy: false, sortOrder: .constant([]), onAction: { _, _ in }, onCompare: { _ in })
        let coordinator = parent.makeCoordinator()
        let table = WorkspaceNativeFilesTable.FileTable()
        table.coordinator = coordinator
        coordinator.table = table; coordinator.update(parent)
        for id in ["filename", "directory"] {
            let column = NSTableColumn(identifier: .init(id))
            let cell = try XCTUnwrap(coordinator.tableView(table, viewFor: column, row: 0) as? WorkspaceNativeFilesTable.Cell)
            XCTAssertEqual(table.fileToolTip(row: 0, column: column), id == "filename" ? "完整的文件名.swift" : path)
            XCTAssertNil(cell.toolTip)
            XCTAssertNil(cell.label.toolTip)
            XCTAssertFalse(cell.label.allowsExpansionToolTips)
        }
    }

    func testStationaryFileTooltipCannotSurviveClearedRowsOrRepositorySwitch() throws {
        _ = NSApplication.shared
        func parent(_ path: String, _ names: [String]) -> WorkspaceNativeFilesTable {
            WorkspaceNativeFilesTable(rows: names.map { .init(path: $0, file: nil) }, files: [],
                repository: GitRepository(url: URL(fileURLWithPath: path)), selection: .constant([]), isBusy: false,
                sortOrder: .constant([]), onAction: { _, _ in }, onCompare: { _ in })
        }
        let original = parent("/tmp/tooltip-original", ["src/committed.swift", "src/another.swift"])
        let coordinator = original.makeCoordinator()
        let table = WorkspaceNativeFilesTable.FileTable()
        table.coordinator = coordinator
        let column = NSTableColumn(identifier: .init("filename")); column.width = 400
        table.addTableColumn(column)
        let directory = NSTableColumn(identifier: .init("directory")); directory.width = 100
        table.addTableColumn(directory)
        table.dataSource = coordinator; table.delegate = coordinator; coordinator.table = table
        coordinator.update(original)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 240)); scroll.documentView = table
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.close() }
        scroll.layoutSubtreeIfNeeded(); table.updateTrackingAreas()
        let point = NSPoint(x: 20, y: table.rect(ofRow: 0).midY)
        let originalTag = try XCTUnwrap(table.fileToolTipTags.first)
        let originalOwner = try XCTUnwrap(table.fileToolTipOwner)
        XCTAssertEqual(table.fileToolTipTags.count, 4, "Each visible cell needs its own region so moving between files changes the hint")
        XCTAssertEqual(table.view(table, stringForToolTip: originalTag, point: point, userData: nil), "committed.swift")
        XCTAssertEqual(table.fileToolTip(at: NSPoint(x: 20, y: table.rect(ofRow: 1).midY)), "another.swift")
        XCTAssertEqual(table.fileToolTip(at: NSPoint(x: table.rect(ofColumn: 1).midX, y: point.y)), "src/committed.swift")

        // Keep the mouse coordinates unchanged while the commit removes all rows.
        coordinator.update(parent("/tmp/tooltip-original", []))
        XCTAssertTrue(table.fileToolTipTags.isEmpty)
        XCTAssertNil(table.fileToolTip(at: point))
        XCTAssertEqual(table.view(table, stringForToolTip: originalTag, point: point, userData: nil), "")

        coordinator.update(parent("/tmp/tooltip-next", ["current.swift"]))
        table.updateTrackingAreas()
        let nextTag = try XCTUnwrap(table.fileToolTipTags.first)
        XCTAssertFalse(try XCTUnwrap(table.fileToolTipOwner) === originalOwner)
        XCTAssertEqual(originalOwner.view(table, stringForToolTip: nextTag, point: point, userData: nil), "")
        XCTAssertEqual(table.view(table, stringForToolTip: nextTag, point: point, userData: nil), "current.swift")
        XCTAssertNil(table.fileToolTip(at: NSPoint(x: 20, y: table.rect(ofRow: 0).maxY + 30)))
        XCTAssertFalse(window.isVisible)
    }

    func testHeaderSortCyclesToDefaultAndDropsPreviousColumnsWithoutChangingSelection() {
        let state = State()
        state.selection = ["b"]
        let parent = WorkspaceNativeFilesTable(rows: ["a", "b"].map { WorkspaceFileRow(path: $0, file: nil) }, files: [], repository: nil,
            selection: Binding(get: { state.selection }, set: { state.selection = $0 }), isBusy: false,
            sortOrder: Binding(get: { state.sort }, set: { state.sort = $0 }), onAction: { _, _ in }, onCompare: { _ in })
        let coordinator = parent.makeCoordinator()
        let table = WorkspaceNativeFilesTable.FileTable()
        table.addTableColumn(NSTableColumn(identifier: .init("filename")))
        table.dataSource = coordinator; table.delegate = coordinator; coordinator.table = table
        coordinator.update(parent)
        for _ in 0..<2 {
            table.sortDescriptors = [NSSortDescriptor(key: "filename", ascending: true)]
            XCTAssertEqual(state.sort, [.init(column: .name, ascending: true)])
            table.sortDescriptors = [NSSortDescriptor(key: "filename", ascending: false)]
            XCTAssertEqual(state.sort, [.init(column: .name, ascending: false)])
            table.sortDescriptors = [NSSortDescriptor(key: "filename", ascending: true)]
            XCTAssertEqual(state.sort, [])
            XCTAssertEqual(table.sortDescriptors, [])
        }
        table.sortDescriptors = [NSSortDescriptor(key: "filename", ascending: true)]
        table.sortDescriptors = [NSSortDescriptor(key: "status", ascending: true), NSSortDescriptor(key: "filename", ascending: true)]
        XCTAssertEqual(state.sort, [.init(column: .status, ascending: true)])
        XCTAssertEqual(table.sortDescriptors.count, 1)
        table.sortDescriptors = []
        XCTAssertEqual(state.sort, [])
        XCTAssertEqual(state.selection, ["b"])
    }

    func testDoubleClickCollapsesMultiSelectionBeforeRunningDefaultAction() {
        let state = State()
        state.selection = ["a", "b"]
        let rows = ["a", "b", "c"].map { WorkspaceFileRow(path: $0, file: nil) }
        var actions: [Set<String>] = []
        var parent = WorkspaceNativeFilesTable(rows: rows, files: [], repository: nil,
            selection: Binding(get: { state.selection }, set: { state.selection = $0 }), isBusy: false,
            sortOrder: .constant([]), onAction: { _, _ in }, onCompare: { paths in
                XCTAssertEqual(state.selection, paths)
                actions.append(paths)
            })
        let coordinator = parent.makeCoordinator()
        let table = WorkspaceNativeFilesTable.FileTable()
        table.addTableColumn(NSTableColumn(identifier: .init("filename")))
        table.allowsMultipleSelection = true
        table.dataSource = coordinator; table.delegate = coordinator; coordinator.table = table
        coordinator.update(parent)
        coordinator.activate(row: 1)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1))
        XCTAssertEqual(actions, [["b"]])
        coordinator.activate(row: 2)
        XCTAssertEqual(state.selection, ["c"])
        XCTAssertEqual(actions, [["b"], ["c"]])
        coordinator.activate(row: -1)
        parent.isReady = false; coordinator.update(parent)
        coordinator.activate(row: 0)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(state.selection, ["c"])
    }

    func testNativeSelectionImmediatelyUpdatesExistingAndReusedCells() {
        let row = NativeSelectionRowView()
        let cell = WorkspaceNativeFilesTable.Cell(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        let normal = NSImage(size: NSSize(width: 16, height: 16))
        let selected = NSImage(size: NSSize(width: 16, height: 16))
        cell.normalIcon = normal; cell.selectedIcon = selected
        cell.foregroundColor = .systemOrange; cell.badgeColor = .systemOrange
        row.addSubview(cell)
        row.isSelected = true
        XCTAssertEqual(cell.label.textColor, .white)
        XCTAssertTrue(cell.icon.image === selected)
        cell.backgroundStyle = .normal
        XCTAssertEqual(cell.label.textColor, .white, "The custom blue selection must keep a contrasting foreground")
        cell.backgroundStyle = .emphasized
        let tree = WorkspaceTreeTable.Cell(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        tree.normalIcon = normal; tree.selectedIcon = selected
        row.addSubview(tree)
        XCTAssertEqual(tree.label.textColor, .white)
        XCTAssertTrue(tree.icon.image === selected)
        row.isSelected = false
        XCTAssertEqual(cell.label.textColor, .systemOrange)
        XCTAssertTrue(cell.icon.image === normal)
        XCTAssertEqual(tree.label.textColor, .labelColor)
        XCTAssertTrue(tree.icon.image === normal)
    }

    func testTextAndIconsShareRowCenterForDifferentFontSizes() {
        let cell = WorkspaceNativeFilesTable.Cell(frame: NSRect(x: 0, y: 0, width: 180, height: 23))
        for size: CGFloat in [10, 12] {
            cell.label.font = .systemFont(ofSize: size)
            cell.label.stringValue = "修改 · 新增"
            cell.needsLayout = true
            cell.layoutSubtreeIfNeeded()
            XCTAssertEqual(cell.label.frame.midY, cell.bounds.midY, accuracy: 0.01)
            XCTAssertEqual(cell.icon.frame.midY, cell.bounds.midY, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(cell.label.frame.height, cell.label.cell!.cellSize.height)
        }
    }

    private final class State: ObservableObject {
        @Published var selection: Set<String> = []
        @Published var sort: [WorkspaceFilePreparation.Sort] = []
        @Published var rows: [WorkspaceFileRow] = []
    }
    private struct Fixture: View {
        @ObservedObject var state: State
        var body: some View {
            WorkspaceNativeFilesTable(rows: state.rows, files: [], repository: nil, selection: $state.selection, isBusy: false, sortOrder: $state.sort, onAction: { _, _ in }, onCompare: { _ in })
        }
    }
    private func table(in view: NSView) -> NSTableView? {
        if let value = view as? NSTableView { return value }
        for child in view.subviews { if let found = table(in: child) { return found } }
        return nil
    }
    func testColdSixThousandRowsAreVirtualizedAndSelectionAndHeaderSortWork() async throws {
        _ = NSApplication.shared
        let state = State()
        state.rows = (0..<6000).map { WorkspaceFileRow(path: "first/file\($0).swift", file: GitFile(path: "first/file\($0).swift", indexStatus: "M", worktreeStatus: " ")) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let start = ContinuousClock.now
        let host = NSHostingView(rootView: Fixture(state: state))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let native = try XCTUnwrap(table(in: host))
        native.layoutSubtreeIfNeeded()
        let elapsed = start.duration(to: .now)
        print("Native workspace cold 6000 rows: \(elapsed)")
        XCTAssertEqual(native.numberOfRows, 6000)
        XCTAssertFalse(native.usesAlternatingRowBackgroundColors, "The document canvas should stay quiet below the file rows")
        // A native table creates cells for the viewport, not for all 6000 identities.
        XCTAssertNil(native.view(atColumn: 0, row: 5999, makeIfNecessary: false))
        native.selectRowIndexes(IndexSet([1, 4]), byExtendingSelection: false)
        XCTAssertEqual(state.selection, ["first/file1.swift", "first/file4.swift"])
        native.sortDescriptors = [NSSortDescriptor(key: "directory", ascending: false)]
        XCTAssertEqual(state.sort, [.init(column: .directory, ascending: false)])
        state.rows = (0..<6000).map { WorkspaceFileRow(path: "second/file\($0).swift", file: nil) }
        state.selection = ["second/file5.swift"]
        for _ in 0..<3 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        XCTAssertEqual(native.numberOfRows, 6000)
        XCTAssertEqual(native.selectedRowIndexes, IndexSet(integer: 5))
        XCTAssertNil(native.view(atColumn: 0, row: 5999, makeIfNecessary: false))
    }

    func testIconsFollowAppearanceAndSelectedStatusRemainsReadable() throws {
        let file = GitFile(path: "a", indexStatus: " ", worktreeStatus: "M")
        let parent = WorkspaceNativeFilesTable(rows: [WorkspaceFileRow(path: file.path, file: file)], files: [file], repository: nil, selection: .constant([]), isBusy: false, sortOrder: .constant([]), onAction: { _, _ in }, onCompare: { _ in })
        let coordinator = WorkspaceNativeFilesTable.Coordinator(parent)
        let table = WorkspaceNativeFilesTable.FileTable()
        let name = NSTableColumn(identifier: .init("filename"))
        let status = NSTableColumn(identifier: .init("status"))
        table.addTableColumn(name); table.addTableColumn(status)
        table.dataSource = coordinator; table.delegate = coordinator; coordinator.table = table
        coordinator.update(parent)
        table.appearance = NSAppearance(named: .aqua)
        let light = try XCTUnwrap(coordinator.tableView(table, viewFor: name, row: 0) as? WorkspaceNativeFilesTable.Cell)
        let lightImage = try XCTUnwrap(light.icon.image)
        table.appearance = NSAppearance(named: .darkAqua)
        let dark = try XCTUnwrap(coordinator.tableView(table, viewFor: name, row: 0) as? WorkspaceNativeFilesTable.Cell)
        let darkImage = try XCTUnwrap(dark.icon.image)
        XCTAssertFalse(lightImage === darkImage)
        table.appearance = NSAppearance(named: .aqua)
        let restored = try XCTUnwrap(coordinator.tableView(table, viewFor: name, row: 0) as? WorkspaceNativeFilesTable.Cell)
        XCTAssertTrue(restored.icon.image === lightImage)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let selected = try XCTUnwrap(coordinator.tableView(table, viewFor: name, row: 0) as? WorkspaceNativeFilesTable.Cell)
        XCTAssertEqual(selected.label.textColor, .white)
        XCTAssertFalse(selected.icon.image === lightImage)
        table.deselectAll(nil)
        let reused = try XCTUnwrap(coordinator.tableView(table, viewFor: name, row: 0) as? WorkspaceNativeFilesTable.Cell)
        XCTAssertEqual(reused.label.textColor, .labelColor)
        XCTAssertTrue(reused.icon.image === lightImage)
        let badge = try XCTUnwrap(coordinator.tableView(table, viewFor: status, row: 0) as? WorkspaceNativeFilesTable.Cell)
        XCTAssertEqual(badge.label.textColor, .systemOrange)
        restored.nativeSelection = nil
        restored.backgroundStyle = .emphasized
        XCTAssertFalse(restored.icon.image === lightImage)
        restored.backgroundStyle = .normal
        XCTAssertTrue(restored.icon.image === lightImage)
        badge.nativeSelection = nil
        badge.backgroundStyle = .emphasized
        XCTAssertEqual(badge.label.textColor, .white)
        badge.backgroundStyle = .normal
        XCTAssertEqual(badge.label.textColor, .systemOrange)
        badge.frame = NSRect(x: 0, y: 0, width: coordinator.statusWidth, height: 22)
        badge.layoutSubtreeIfNeeded()
        let needed = ceil((badge.label.stringValue as NSString).size(withAttributes: [.font: try XCTUnwrap(badge.label.font)]).width)
        XCTAssertGreaterThanOrEqual(badge.label.frame.width, needed + 4, "Status labels must fit actual glyphs and native text-cell insets, including after reuse")
        badge.label.stringValue = "已暂存 · 已修改"
        badge.needsLayout = true; badge.layoutSubtreeIfNeeded()
        let chineseWidth = ceil((badge.label.stringValue as NSString).size(withAttributes: [.font: try XCTUnwrap(badge.label.font)]).width)
        XCTAssertGreaterThanOrEqual(badge.label.frame.width, chineseWidth + 4)
    }

    func testMouseTrackingPreservesNativeClickAndRejectsOldRepositoryCompletion() {
        let state = State()
        state.selection = ["a"]
        let rows = [WorkspaceFileRow(path: "a", file: nil), WorkspaceFileRow(path: "b", file: nil)]
        var writes: [Set<String>] = []
        let selection = Binding(get: { state.selection }, set: { paths in writes.append(paths); state.selection = paths })
        func parent(_ repositoryPath: String) -> WorkspaceNativeFilesTable {
            WorkspaceNativeFilesTable(rows: rows, files: [], repository: GitRepository(url: URL(fileURLWithPath: repositoryPath)), selection: selection, isBusy: false, sortOrder: .constant([]), onAction: { _, _ in }, onCompare: { _ in })
        }
        let first = parent("/mouse-tracking-first")
        let coordinator = WorkspaceNativeFilesTable.Coordinator(first)
        let table = WorkspaceNativeFilesTable.FileTable()
        table.addTableColumn(NSTableColumn(identifier: .init("filename")))
        table.dataSource = coordinator; table.delegate = coordinator
        table.coordinator = coordinator; coordinator.table = table
        coordinator.update(first)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 0))

        let sameGeneration = coordinator.mouseGeneration
        table.isTrackingMouse = true
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        // Simulate the old SwiftUI binding arriving during AppKit's mouse tracking loop.
        state.selection = ["a"]
        coordinator.update(first)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1))
        XCTAssertEqual(state.selection, ["a"])
        table.isTrackingMouse = false
        coordinator.finishMouseTracking(generation: sameGeneration)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1))
        XCTAssertEqual(state.selection, ["b"])

        let oldGeneration = coordinator.mouseGeneration
        table.isTrackingMouse = true
        state.selection = ["a"]
        writes.removeAll()
        coordinator.update(parent("/mouse-tracking-second"))
        XCTAssertNotEqual(coordinator.mouseGeneration, oldGeneration)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 0))
        table.isTrackingMouse = false
        coordinator.finishMouseTracking(generation: oldGeneration)
        XCTAssertEqual(state.selection, ["a"], "An old repository's click must not overwrite the new repository's selection")
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 0))
        XCTAssertTrue(writes.isEmpty, "Completing an old mouse generation must not publish a selection")
    }

    func testHeaderMenuIsReusedWhileColumnChecksAndLanguageStayCurrent() throws {
        let defaults = UserDefaults.standard
        let oldLanguage = defaults.object(forKey: L10n.preferenceKey)
        defer {
            if let oldLanguage { defaults.set(oldLanguage, forKey: L10n.preferenceKey) }
            else { defaults.removeObject(forKey: L10n.preferenceKey) }
        }
        defaults.set("en", forKey: L10n.preferenceKey)
        let state = State()
        state.selection = ["a"]
        let rows = [WorkspaceFileRow(path: "a", file: nil), WorkspaceFileRow(path: "b", file: nil)]
        var parent = WorkspaceNativeFilesTable(rows: rows, files: [], repository: nil, selection: Binding(get: { state.selection }, set: { state.selection = $0 }), isBusy: false, sortOrder: .constant([]), onAction: { _, _ in }, onCompare: { _ in })
        let coordinator = WorkspaceNativeFilesTable.Coordinator(parent)
        let table = WorkspaceNativeFilesTable.FileTable()
        table.headerView = NSTableHeaderView(frame: .zero)
        for column in WorkspaceNativeFilesTable.Coordinator.columns { table.addTableColumn(NSTableColumn(identifier: .init(column.id))) }
        table.dataSource = coordinator; table.delegate = coordinator; coordinator.table = table
        coordinator.update(parent)
        let menu = try XCTUnwrap(table.headerView?.menu)
        let nameItem = menu.items[0], statusItem = menu.items[1], workspaceItem = menu.items[2]
        XCTAssertEqual(nameItem.state, .on)
        XCTAssertFalse(nameItem.isEnabled)
        XCTAssertEqual(statusItem.state, .on)
        XCTAssertEqual(workspaceItem.state, .off)
        state.selection = ["b"]
        coordinator.update(parent)
        XCTAssertTrue(table.headerView?.menu === menu)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1))
        parent.visibleColumns = ["filename", "workspace", "directory"]
        coordinator.update(parent)
        XCTAssertTrue(table.headerView?.menu === menu)
        XCTAssertEqual(statusItem.state, .off)
        XCTAssertEqual(workspaceItem.state, .on)
        let status = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "status" })
        let workspace = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "workspace" })
        XCTAssertTrue(status.isHidden)
        XCTAssertFalse(workspace.isHidden)
        let englishName = nameItem.title
        defaults.set("zh-Hans", forKey: L10n.preferenceKey)
        coordinator.update(parent)
        XCTAssertTrue(table.headerView?.menu === menu)
        XCTAssertEqual(nameItem.title, L10n.text("name", table: "Files"))
        XCTAssertNotEqual(nameItem.title, englishName)
        XCTAssertEqual(table.tableColumns[0].title, nameItem.title)
        XCTAssertGreaterThanOrEqual(status.width, coordinator.statusWidth)
        XCTAssertLessThan(status.minWidth, status.maxWidth)
        XCTAssertEqual(statusItem.state, .off)
        XCTAssertEqual(workspaceItem.state, .on)
    }

    func testLocalizedDualStatusFitsAndBothAdjacentColumnsRemainResizable() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let oldLanguage = defaults.object(forKey: L10n.preferenceKey)
        defer {
            if let oldLanguage { defaults.set(oldLanguage, forKey: L10n.preferenceKey) }
            else { defaults.removeObject(forKey: L10n.preferenceKey) }
        }
        for language in ["en", "zh-Hans", "zh-Hant", "ja"] {
            defaults.set(language, forKey: L10n.preferenceKey)
            let state = State()
            let file = GitFile(path: "dual-status", indexStatus: "A", worktreeStatus: "M")
            state.rows = [WorkspaceFileRow(path: file.path, file: file)]
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let host = NSHostingView(rootView: Fixture(state: state))
            window.contentView = host
            for _ in 0..<5 { host.layoutSubtreeIfNeeded(); await Task.yield() }
            let table = try XCTUnwrap(self.table(in: host) as? WorkspaceNativeFilesTable.FileTable)
            let coordinator = try XCTUnwrap(table.coordinator)
            let statusIndex = try XCTUnwrap(table.tableColumns.firstIndex { $0.identifier.rawValue == "status" })
            let status = table.tableColumns[statusIndex]
            let filename = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "filename" })
            window.setContentSize(NSSize(width: 430, height: 200))
            for _ in 0..<5 { host.layoutSubtreeIfNeeded(); await Task.yield() }
            let cell = try XCTUnwrap(table.view(atColumn: statusIndex, row: 0, makeIfNecessary: true) as? WorkspaceNativeFilesTable.Cell)
            cell.layoutSubtreeIfNeeded()
            let required = try XCTUnwrap(cell.label.cell).cellSize.width
            XCTAssertGreaterThanOrEqual(cell.label.frame.width + 0.01, required, "The complete dual-status text must fit in \(language)")
            XCTAssertEqual(cell.label.stringValue, WorkspaceFileStatus(file).keys.map { L10n.text($0, table: "Files") }.joined(separator: " · "))
            XCTAssertTrue(filename.resizingMask.contains(.userResizingMask))
            XCTAssertTrue(status.resizingMask.contains(.userResizingMask))
            XCTAssertFalse(status.resizingMask.contains(.autoresizingMask))
            XCTAssertLessThan(status.minWidth, status.maxWidth)
            let resized = status.width + 40
            status.width = resized
            coordinator.update(coordinator.parent)
            XCTAssertEqual(status.width, resized, accuracy: 0.01, "An ordinary view update must preserve the user's header resize")
        }
    }

    func testContextMenuUsesClickedRowAndPreservesSelectedGroup() throws {
        let selection = State()
        let rows = [WorkspaceFileRow(path: "a", file: nil), WorkspaceFileRow(path: "b", file: nil)]
        let parent = WorkspaceNativeFilesTable(rows: rows, files: [], repository: nil, selection: Binding(get: { selection.selection }, set: { selection.selection = $0 }), isBusy: false, sortOrder: .constant([]), onAction: { _, _ in }, onCompare: { _ in })
        let coordinator = WorkspaceNativeFilesTable.Coordinator(parent)
        let table = WorkspaceNativeFilesTable.FileTable(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        table.addTableColumn(NSTableColumn(identifier: .init("filename")))
        table.allowsMultipleSelection = true
        table.dataSource = coordinator; table.delegate = coordinator; coordinator.table = table
        coordinator.update(parent)
        table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        let menu = try XCTUnwrap(coordinator.menu(at: NSPoint(x: 10, y: table.rect(ofRow: 1).midY)))
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.count, 11)
        XCTAssertEqual(selection.selection, ["a", "b"])
        XCTAssertTrue(menu.items.allSatisfy { !$0.isEnabled })
    }
}
