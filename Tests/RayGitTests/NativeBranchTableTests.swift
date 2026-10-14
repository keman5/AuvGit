import XCTest
import AppKit
import SwiftUI
import GitCore
@testable import RayGit

@MainActor
final class NativeBranchTableTests: XCTestCase {
    func testSelectionImmediatelyTintsAllBranchIconsAndSurvivesReuse() throws {
        let parent = pane()
        let coordinator = parent.makeCoordinator()
        let value = try XCTUnwrap(parent.rows.first { $0.current })
        let cell = NativeBranchTable.Cell(frame: .zero)
        cell.configure(value, coordinator: coordinator)
        let row = NativeBranchTable.RowView()
        row.addSubview(cell)
        row.isSelected = true
        for icon in [cell.icon, cell.tracking, cell.check] {
            XCTAssertEqual(icon.contentTintColor, .alternateSelectedControlTextColor)
        }
        cell.configure(value, coordinator: coordinator)
        XCTAssertEqual(cell.check.contentTintColor, .alternateSelectedControlTextColor)
        row.isSelected = false
        XCTAssertEqual(cell.label.textColor, .labelColor)
        XCTAssertEqual(cell.check.contentTintColor, .controlAccentColor)
        XCTAssertEqual(cell.tracking.contentTintColor, .secondaryLabelColor)
    }

    func testCurrentBranchOmitsMergeButOtherBranchesKeepIt() throws {
        let coordinator = pane().makeCoordinator()
        coordinator.rows = coordinator.parent.rows
        for (index, row) in coordinator.rows.enumerated() where row.id.hasPrefix("branch:") || row.id.hasPrefix("remote:") {
            let menu = try XCTUnwrap(coordinator.menu(row: index))
            let hasMerge = menu.items.contains { ($0.representedObject as? NativeBranchTable.Coordinator.MenuAction)?.action == .merge }
            XCTAssertEqual(hasMerge, !row.current)
        }
    }

    func testDoubleClickAppliesClickedStashImmediatelyAndDoesNothingWhileBusy() throws {
        var received: [(SidebarAction, String)] = []
        let view = pane(action: { received.append(($0, $1)) })
        let coordinator = view.makeCoordinator(); coordinator.update(view)
        let index = try XCTUnwrap(coordinator.rows.firstIndex { $0.id == "stash:stash@{0}" })
        coordinator.activate(row: index)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, .stashApplyImmediately)
        XCTAssertEqual(received.first?.1, "stash@{0}")
        coordinator.update(pane(busy: true, action: { received.append(($0, $1)) }))
        coordinator.activate(row: index)
        XCTAssertEqual(received.count, 1)
    }
    func testLocalBranchCreationTargetsClickedBranchAndIsDisabledWhileBusy() throws {
        var received: String?
        var view = pane()
        view = NativeBranchTable(branches: view.branches, stashes: [], repositoryPath: view.repositoryPath,
            currentBranch: view.currentBranch, isBusy: false, localExpanded: .constant(true),
            stashesExpanded: .constant(true), selection: .constant(nil),
            onAction: { action, value in if action == .createBranchFromLocal { received = value } },
            onRenameStash: { _ in }, onShortcut: { _ in false })
        let coordinator = view.makeCoordinator(); coordinator.update(view)
        for (index, row) in coordinator.rows.enumerated() where row.id.hasPrefix("branch:") {
            let menu = try XCTUnwrap(coordinator.menu(row: index))
            let item = try XCTUnwrap(menu.items.first {
                ($0.representedObject as? NativeBranchTable.Coordinator.MenuAction)?.action == .createBranchFromLocal
            })
            XCTAssertTrue(item.isEnabled)
            coordinator.performMenuAction(item)
            XCTAssertEqual(received, row.target)
        }
        coordinator.update(pane(busy: true))
        let index = try XCTUnwrap(coordinator.rows.firstIndex { $0.id.hasPrefix("branch:") })
        let item = try XCTUnwrap(coordinator.menu(row: index)?.items.first {
            ($0.representedObject as? NativeBranchTable.Coordinator.MenuAction)?.action == .createBranchFromLocal
        })
        XCTAssertFalse(item.isEnabled)
    }
    func testDisclosureUsesFixedSlotAndNoScrollTopInset() {
        let parent = pane()
        let coordinator = parent.makeCoordinator()
        let cell = NativeBranchTable.Cell(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        for row in parent.rows.filter({ $0.isGroup }) {
            var row = row
            cell.configure(row, coordinator: coordinator); cell.layoutSubtreeIfNeeded()
            let icon = cell.icon.frame, label = cell.label.frame
            row.expanded = false
            cell.configure(row, coordinator: coordinator); cell.layoutSubtreeIfNeeded()
            XCTAssertEqual(cell.icon.frame, icon); XCTAssertEqual(cell.label.frame, label)
            XCTAssertEqual(cell.icon.frame.width, 10)
            XCTAssertEqual(cell.icon.frame.minX, 10 + CGFloat(row.depth) * 14)
            XCTAssertEqual(cell.icon.frame.midY, cell.bounds.midY)
            XCTAssertEqual(cell.label.frame.minX, 22 + CGFloat(row.depth) * 14)
            XCTAssertEqual(cell.label.frame.minX - cell.icon.frame.maxX, 2)
            XCTAssertEqual(cell.disclosure.title, "")
            XCTAssertEqual(cell.label.stringValue, row.title)
            XCTAssertTrue(cell.hitTest(NSPoint(x: cell.label.frame.midX, y: cell.label.frame.midY)) === cell.disclosure)
        }
        cell.configure(parent.rows.first(where: { $0.id == "branch:main" })!, coordinator: coordinator)
        cell.layoutSubtreeIfNeeded()
        XCTAssertEqual(cell.icon.frame.width, 14)
        XCTAssertEqual(cell.icon.frame.minX, 22)
        XCTAssertEqual(cell.label.frame.minX - cell.icon.frame.maxX, 2)
    }
    func testTrackingMarkerKeepsCurrentMarkerAndClearsOnReuse() throws {
        var parent = pane()
        parent = NativeBranchTable(branches: [GitBranch(name: "main", isCurrent: true, isRemote: false, upstream: "origin/main"), GitBranch(name: "origin/main", isCurrent: false, isRemote: true)],
            stashes: [], repositoryPath: parent.repositoryPath, currentBranch: "main", isBusy: false,
            localExpanded: .constant(true), stashesExpanded: .constant(true), selection: .constant(nil),
            onAction: { _, _ in }, onRenameStash: { _ in }, onShortcut: { _ in false })
        let coordinator = parent.makeCoordinator()
        let cell = NativeBranchTable.Cell(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        for row in parent.rows {
            cell.configure(row, coordinator: coordinator); cell.layoutSubtreeIfNeeded()
            XCTAssertEqual(cell.label.frame.minX - cell.icon.frame.maxX, 2)
            XCTAssertEqual(cell.tracking.isHidden, row.upstream == nil)
            if row.upstream != nil {
                XCTAssertFalse(cell.check.isHidden)
                XCTAssertGreaterThanOrEqual(cell.label.frame.width, (row.title as NSString).size(withAttributes: [.font: cell.label.font!]).width)
                XCTAssertEqual(cell.tracking.frame.minX - cell.label.frame.maxX, 4)
                XCTAssertLessThan(cell.tracking.frame.maxX, cell.check.frame.minX)
                XCTAssertEqual(cell.tracking.frame.midY, cell.bounds.midY)
                XCTAssertTrue(try XCTUnwrap(cell.accessibilityHelp()).contains("origin/main"))
            } else { XCTAssertNil(cell.accessibilityHelp()) }
        }
    }
    func testBranchTextIconAndCurrentMarkerShareRowCenter() {
        let cell = NativeBranchTable.Cell(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        cell.label.font = .systemFont(ofSize: 12, weight: .semibold)
        cell.label.stringValue = "feature/分支"
        cell.needsLayout = true
        cell.layoutSubtreeIfNeeded()
        for view in [cell.disclosure, cell.icon, cell.label, cell.check] {
            XCTAssertEqual(view.frame.midY, cell.bounds.midY, accuracy: 0.01)
        }
        XCTAssertGreaterThanOrEqual(cell.label.frame.height, cell.label.cell!.cellSize.height)
    }

    private func pane(path: String = "/first", busy: Bool = false, action: @escaping (SidebarAction, String) -> Void = { _, _ in }) -> NativeBranchTable {
        NativeBranchTable(branches: [GitBranch(name: "main", isCurrent: true, isRemote: false), GitBranch(name: "origin/main", isCurrent: false, isRemote: true)],
            stashes: [GitStash(ref: "stash@{0}", subject: "Saved work")], repositoryPath: path, currentBranch: "main", isBusy: busy,
            localExpanded: .constant(true), stashesExpanded: .constant(true),
            selection: .constant(nil), onAction: action, onRenameStash: { _ in }, onShortcut: { _ in false })
    }
    func testCollapsedGroupsKeepHeadersAndStableSelectionTags() {
        var view = pane()
        XCTAssertEqual(view.rows.map(\.id), ["group:local", "branch:main", "folder:remote:origin", "remote:origin/main", "group:stash", "stash:stash@{0}"])
        var expanded = true
        view = NativeBranchTable(branches: view.branches, stashes: view.stashes, repositoryPath: view.repositoryPath,
            currentBranch: view.currentBranch, isBusy: false, localExpanded: Binding(get: { expanded }, set: { expanded = $0 }),
            stashesExpanded: .constant(false), selection: .constant(nil),
            onAction: { _, _ in }, onRenameStash: { _ in }, onShortcut: { _ in false })
        let coordinator = view.makeCoordinator()
        let button = NSButton(); button.identifier = .init("group:local")
        coordinator.toggle(button)
        XCTAssertFalse(expanded)
        let remote = NSButton(); remote.identifier = .init("folder:remote:origin")
        coordinator.toggle(remote)
        XCTAssertEqual(coordinator.rows.map(\.id), ["group:local", "folder:remote:origin", "group:stash"])
        let cell = NativeBranchTable.Cell(frame: .zero)
        cell.configure(view.rows[0], coordinator: coordinator)
        XCTAssertEqual(cell.disclosure.accessibilityValue() as? String, sidebarRefinementText("Collapsed"))
        XCTAssertEqual(cell.disclosure.accessibilityLabel(), interactionText("Local Branches"))
    }
    func testCurrentBranchAndBusyMenuRetainCorrectPermissions() throws {
        let coordinator = pane().makeCoordinator(); coordinator.rows = coordinator.parent.rows
        let menu = try XCTUnwrap(coordinator.menu(row: 1))
        XCTAssertFalse(menu.items.contains { ($0.representedObject as? NativeBranchTable.Coordinator.MenuAction)?.action == .history })
        XCTAssertFalse(try XCTUnwrap(menu.items.first { ($0.representedObject as? NativeBranchTable.Coordinator.MenuAction)?.action == .delete }).isEnabled)
        coordinator.parent = pane(busy: true)
        let busy = try XCTUnwrap(coordinator.menu(row: 1))
        for item in busy.items where !item.isSeparatorItem {
            XCTAssertEqual(item.isEnabled, (item.representedObject as? NativeBranchTable.Coordinator.MenuAction)?.action == .copy)
        }
    }
    func testMenusFollowTrackingCurrentAndWorktreeStateAtExecution() throws {
        var actions: [SidebarAction] = []
        var view = pane(action: { action, _ in actions.append(action) })
        view = NativeBranchTable(branches: [
            GitBranch(name: "main", isCurrent: true, isRemote: false, upstream: "origin/main"),
            GitBranch(name: "topic", isCurrent: false, isRemote: false, worktreePath: "/other"),
            GitBranch(name: "origin/main", isCurrent: false, isRemote: true)
        ], stashes: [], repositoryPath: "/first", currentBranch: "main", isBusy: false,
            localExpanded: .constant(true), stashesExpanded: .constant(true), selection: .constant(nil),
            onAction: view.onAction, onRenameStash: { _ in }, onShortcut: { _ in false })
        let coordinator = view.makeCoordinator(); coordinator.update(view)
        func item(_ action: SidebarAction, id: String) throws -> NSMenuItem? {
            let row = try XCTUnwrap(coordinator.rows.firstIndex { $0.id == id })
            return coordinator.menu(row: row)?.items.first { ($0.representedObject as? NativeBranchTable.Coordinator.MenuAction)?.action == action }
        }
        XCTAssertFalse(try XCTUnwrap(item(.checkout, id: "branch:main")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(item(.delete, id: "branch:topic")).isEnabled)
        XCTAssertTrue(try XCTUnwrap(item(.checkout, id: "branch:topic")).isEnabled, "A linked worktree can be opened")
        XCTAssertNil(try item(.stopTracking, id: "branch:topic"))
        XCTAssertTrue(try XCTUnwrap(item(.deleteRemote, id: "remote:origin/main")).isEnabled)
        let staleTracking = try XCTUnwrap(item(.stopTracking, id: "branch:main"))
        coordinator.parent = pane(action: view.onAction)
        coordinator.performMenuAction(staleTracking)
        XCTAssertTrue(actions.isEmpty)
        coordinator.update(coordinator.parent)
        XCTAssertNil(try item(.stopTracking, id: "branch:main"))
        XCTAssertNil(try item(.stopTracking, id: "remote:origin/main"))
    }
    func testBranchScrollerReservesSpaceForStatusMarkers() throws {
        var view = pane()
        view = NativeBranchTable(branches: (0..<80).map { GitBranch(name: "branch\($0)", isCurrent: $0 == 0, isRemote: false, upstream: "origin/branch\($0)") },
            stashes: [], repositoryPath: "/first", currentBranch: "branch0", isBusy: false,
            localExpanded: .constant(true), stashesExpanded: .constant(true), selection: .constant(nil),
            onAction: { _, _ in }, onRenameStash: { _ in }, onShortcut: { _ in false })
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> NativeBranchTable.Table? {
            if let table = view as? NativeBranchTable.Table { return table }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        let table = try XCTUnwrap(find(host)), scroll = try XCTUnwrap(table.enclosingScrollView)
        scroll.tile(); table.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.scrollerStyle, .legacy)
        XCTAssertFalse(try XCTUnwrap(scroll.verticalScroller).isHidden)
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NativeBranchTable.Cell)
        cell.layoutSubtreeIfNeeded()
        let check = cell.convert(cell.check.frame, to: scroll)
        XCTAssertLessThanOrEqual(check.maxX, try XCTUnwrap(scroll.verticalScroller).frame.minX)
    }
    func testOldContextMenuCannotActOnNewRepositoryAndRemoteUsesFullReference() throws {
        var actions: [String] = []
        let coordinator = pane(action: { _, target in actions.append(target) }).makeCoordinator()
        coordinator.rows = coordinator.parent.rows
        let menu = try XCTUnwrap(coordinator.menu(row: 3))
        XCTAssertFalse(menu.items.contains { ($0.representedObject as? NativeBranchTable.Coordinator.MenuAction)?.action == .history })
        let merge = try XCTUnwrap(menu.items.first { ($0.representedObject as? NativeBranchTable.Coordinator.MenuAction)?.action == .merge })
        coordinator.performMenuAction(merge)
        XCTAssertEqual(actions, ["refs/remotes/origin/main"])
        coordinator.parent = pane(path: "/second", action: { _, target in actions.append(target) })
        coordinator.performMenuAction(merge)
        XCTAssertEqual(actions.count, 1)
        coordinator.activate(row: 3)
        XCTAssertEqual(actions.last, "refs/remotes/origin/main")
        let firstRepository = GitRepository(url: URL(fileURLWithPath: "/second"))
        let replacement = GitRepository(url: URL(fileURLWithPath: "/second"))
        coordinator.parent.repositoryIdentity = ObjectIdentifier(firstRepository)
        let samePathMenu = try XCTUnwrap(coordinator.menu(row: 3))
        let staleMerge = try XCTUnwrap(samePathMenu.items.first { ($0.representedObject as? NativeBranchTable.Coordinator.MenuAction)?.action == .merge })
        coordinator.parent.repositoryIdentity = ObjectIdentifier(replacement)
        let count = actions.count
        coordinator.performMenuAction(staleMerge)
        XCTAssertEqual(actions.count, count)
    }
    func testSelectionUpdatesUseCurrentRowsAndHeadersCannotBeSelected() {
        var selection: String?
        let value = pane()
        let view = NativeBranchTable(branches: value.branches, stashes: value.stashes, repositoryPath: value.repositoryPath,
            currentBranch: value.currentBranch, isBusy: false, localExpanded: .constant(true),
            stashesExpanded: .constant(true), selection: Binding(get: { selection }, set: { selection = $0 }),
            onAction: { _, _ in }, onRenameStash: { _ in }, onShortcut: { _ in false })
        let coordinator = view.makeCoordinator()
        let table = NativeBranchTable.Table(); table.addTableColumn(NSTableColumn(identifier: .init("branch")))
        table.dataSource = coordinator; table.delegate = coordinator; coordinator.table = table; coordinator.update(view)
        XCTAssertFalse(coordinator.tableView(table, shouldSelectRow: 0))
        table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        XCTAssertEqual(selection, "remote:origin/main")
    }
    func testNestedBranchesKeepFullTargetsAndFoldersOnlyExpand() throws {
        var actions: [String] = []
        let value = pane(action: { _, target in actions.append(target) })
        let branches = [GitBranch(name: "feature/foo", isCurrent: true, isRemote: false),
            GitBranch(name: "feature/team/bar", isCurrent: false, isRemote: false),
            GitBranch(name: "origin/foo/bar", isCurrent: false, isRemote: true)]
        var view = NativeBranchTable(branches: branches, stashes: [], repositoryPath: "/first", currentBranch: "feature/foo", isBusy: false,
            localExpanded: .constant(true), stashesExpanded: .constant(true), selection: .constant(nil),
            onAction: value.onAction, onRenameStash: { _ in }, onShortcut: { _ in false })
        let coordinator = view.makeCoordinator(); coordinator.update(view)
        XCTAssertEqual(coordinator.rows.map(\.id), ["group:local", "folder:local:feature", "branch:feature/foo", "folder:local:feature/team",
            "branch:feature/team/bar", "folder:remote:origin", "folder:remote:origin/foo", "remote:origin/foo/bar"])
        let leaf = try XCTUnwrap(coordinator.rows.first { $0.id == "remote:origin/foo/bar" })
        XCTAssertEqual(leaf.title, "bar"); XCTAssertEqual(leaf.depth, 2); XCTAssertEqual(leaf.target, "origin/foo/bar")
        XCTAssertNil(coordinator.menu(row: 1))
        coordinator.activate(row: 1)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertFalse(coordinator.rows.contains { $0.id == "branch:feature/foo" })
        XCTAssertTrue(coordinator.setExpanded(row: 1, expanded: true))
        XCTAssertTrue(coordinator.rows.contains { $0.current })
        let team = NSButton(); team.identifier = .init("folder:local:feature/team")
        coordinator.toggle(team)
        XCTAssertFalse(coordinator.rows.contains { $0.id == "branch:feature/team/bar" })
        let changedBranches = branches.map { GitBranch(name: $0.name, isCurrent: $0.name == "feature/team/bar", isRemote: $0.isRemote) }
        let changed = NativeBranchTable(branches: changedBranches, stashes: [], repositoryPath: "/first", currentBranch: "feature/team/bar", isBusy: false,
            localExpanded: .constant(true), stashesExpanded: .constant(true), selection: .constant(nil),
            onAction: value.onAction, onRenameStash: { _ in }, onShortcut: { _ in false })
        coordinator.update(changed)
        XCTAssertTrue(coordinator.rows.contains { $0.id == "branch:feature/team/bar" && $0.current }, "A changed current branch must reveal its ancestors")
        let remoteIndex = try XCTUnwrap(coordinator.rows.firstIndex { $0.id == leaf.id })
        coordinator.activate(row: remoteIndex)
        XCTAssertEqual(actions.last, "refs/remotes/origin/foo/bar")
        let menu = try XCTUnwrap(coordinator.menu(row: remoteIndex))
        XCTAssertEqual((menu.items.first?.representedObject as? NativeBranchTable.Coordinator.MenuAction)?.action, .createLocalBranch)
        coordinator.performMenuAction(try XCTUnwrap(menu.items.first))
        XCTAssertEqual(actions.last, "origin/foo/bar")
        let copy = try XCTUnwrap(menu.items.first { ($0.representedObject as? NativeBranchTable.Coordinator.MenuAction)?.action == .copy })
        coordinator.performMenuAction(copy)
        XCTAssertEqual(actions.last, "origin/foo/bar")
        let button = NSButton(); button.identifier = .init("folder:remote:origin")
        coordinator.toggle(button)
        XCTAssertFalse(coordinator.rows.contains { $0.id == leaf.id })
        view = NativeBranchTable(branches: branches, stashes: [], repositoryPath: "/second", currentBranch: "feature/foo", isBusy: true,
            localExpanded: .constant(true), stashesExpanded: .constant(true), selection: .constant(nil),
            onAction: value.onAction, onRenameStash: { _ in }, onShortcut: { _ in false })
        coordinator.update(view)
        XCTAssertTrue(coordinator.rows.contains { $0.id == leaf.id }, "Folder collapse must not leak across projects")
    }
    func testBusyUpdatesReuseTreeAndAllowFolderNavigation() {
        var view = pane()
        let coordinator = view.makeCoordinator(); coordinator.update(view)
        let button = NSButton(); button.identifier = .init("folder:remote:origin")
        coordinator.toggle(button)
        coordinator.treeRows[1] = .init(id: "branch:main", title: "Cached topology", symbol: "arrow.triangle.branch", depth: 1, current: true)
        view = pane(busy: true)
        coordinator.update(view)
        XCTAssertEqual(coordinator.treeRows[1].title, "Cached topology", "Busy-only updates must not reconstruct the branch tree")
        XCTAssertFalse(coordinator.rows.contains { $0.id == "remote:origin/main" })
        XCTAssertTrue(coordinator.setExpanded(row: 2, expanded: true), "Navigation remains available while busy")
        XCTAssertTrue(coordinator.rows.contains { $0.id == "remote:origin/main" })
    }

}
