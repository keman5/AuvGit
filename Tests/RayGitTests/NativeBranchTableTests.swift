import XCTest
import AppKit
import SwiftUI
import GitCore
@testable import RayGit

@MainActor
final class NativeBranchTableTests: XCTestCase {
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
            localExpanded: .constant(true), remoteExpanded: .constant(true), stashesExpanded: .constant(true),
            selection: .constant(nil), onAction: action, onRenameStash: { _ in }, onShortcut: { _ in false })
    }
    func testCollapsedGroupsKeepHeadersAndStableSelectionTags() {
        var view = pane()
        XCTAssertEqual(view.rows.map(\.id), ["group:local", "branch:main", "group:remote", "folder:remote:origin", "remote:origin/main", "group:stash", "stash:stash@{0}"])
        var expanded = true
        view = NativeBranchTable(branches: view.branches, stashes: view.stashes, repositoryPath: view.repositoryPath,
            currentBranch: view.currentBranch, isBusy: false, localExpanded: Binding(get: { expanded }, set: { expanded = $0 }),
            remoteExpanded: .constant(false), stashesExpanded: .constant(false), selection: .constant(nil),
            onAction: { _, _ in }, onRenameStash: { _ in }, onShortcut: { _ in false })
        let coordinator = view.makeCoordinator()
        let button = NSButton(); button.identifier = .init("group:local")
        coordinator.toggle(button)
        XCTAssertFalse(expanded)
        XCTAssertEqual(view.rows.map(\.id), ["group:local", "group:remote", "group:stash"])
        let cell = NativeBranchTable.Cell(frame: .zero)
        cell.configure(view.rows[0], coordinator: coordinator)
        XCTAssertEqual(cell.disclosure.accessibilityValue() as? String, sidebarRefinementText("Collapsed"))
        XCTAssertEqual(cell.disclosure.accessibilityLabel(), interactionText("Local Branches"))
    }
    func testCurrentBranchAndBusyMenuRetainCorrectPermissions() throws {
        let coordinator = pane().makeCoordinator(); coordinator.rows = coordinator.parent.rows
        let menu = try XCTUnwrap(coordinator.menu(row: 1))
        XCTAssertFalse(try XCTUnwrap(menu.items.first { ($0.representedObject as? NativeBranchTable.Coordinator.MenuAction)?.action == .delete }).isEnabled)
        coordinator.parent = pane(busy: true)
        let busy = try XCTUnwrap(coordinator.menu(row: 1))
        for item in busy.items where !item.isSeparatorItem {
            XCTAssertEqual(item.isEnabled, (item.representedObject as? NativeBranchTable.Coordinator.MenuAction)?.action == .copy)
        }
    }
    func testOldContextMenuCannotActOnNewRepositoryAndRemoteUsesFullReference() throws {
        var actions: [String] = []
        let coordinator = pane(action: { _, target in actions.append(target) }).makeCoordinator()
        coordinator.rows = coordinator.parent.rows
        let menu = try XCTUnwrap(coordinator.menu(row: 4))
        let log = try XCTUnwrap(menu.items.first { ($0.representedObject as? NativeBranchTable.Coordinator.MenuAction)?.action == .history })
        coordinator.performMenuAction(log)
        XCTAssertEqual(actions, ["refs/remotes/origin/main"])
        coordinator.parent = pane(path: "/second", action: { _, target in actions.append(target) })
        coordinator.performMenuAction(log)
        XCTAssertEqual(actions.count, 1)
        coordinator.activate(row: 4)
        XCTAssertEqual(actions.last, "refs/remotes/origin/main")
        let firstRepository = GitRepository(url: URL(fileURLWithPath: "/second"))
        let replacement = GitRepository(url: URL(fileURLWithPath: "/second"))
        coordinator.parent.repositoryIdentity = ObjectIdentifier(firstRepository)
        let samePathMenu = try XCTUnwrap(coordinator.menu(row: 4))
        let staleLog = try XCTUnwrap(samePathMenu.items.first { ($0.representedObject as? NativeBranchTable.Coordinator.MenuAction)?.action == .history })
        coordinator.parent.repositoryIdentity = ObjectIdentifier(replacement)
        let count = actions.count
        coordinator.performMenuAction(staleLog)
        XCTAssertEqual(actions.count, count)
    }
    func testSelectionUpdatesUseCurrentRowsAndHeadersCannotBeSelected() {
        var selection: String?
        let value = pane()
        let view = NativeBranchTable(branches: value.branches, stashes: value.stashes, repositoryPath: value.repositoryPath,
            currentBranch: value.currentBranch, isBusy: false, localExpanded: .constant(true), remoteExpanded: .constant(true),
            stashesExpanded: .constant(true), selection: Binding(get: { selection }, set: { selection = $0 }),
            onAction: { _, _ in }, onRenameStash: { _ in }, onShortcut: { _ in false })
        let coordinator = view.makeCoordinator()
        let table = NativeBranchTable.Table(); table.addTableColumn(NSTableColumn(identifier: .init("branch")))
        table.dataSource = coordinator; table.delegate = coordinator; coordinator.table = table; coordinator.update(view)
        XCTAssertFalse(coordinator.tableView(table, shouldSelectRow: 0))
        table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
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
            localExpanded: .constant(true), remoteExpanded: .constant(true), stashesExpanded: .constant(true), selection: .constant(nil),
            onAction: value.onAction, onRenameStash: { _ in }, onShortcut: { _ in false })
        let coordinator = view.makeCoordinator(); coordinator.update(view)
        XCTAssertEqual(coordinator.rows.map(\.id), ["group:local", "folder:local:feature", "branch:feature/foo", "folder:local:feature/team",
            "branch:feature/team/bar", "group:remote", "folder:remote:origin", "folder:remote:origin/foo", "remote:origin/foo/bar", "group:stash"])
        let leaf = try XCTUnwrap(coordinator.rows.first { $0.id == "remote:origin/foo/bar" })
        XCTAssertEqual(leaf.title, "bar"); XCTAssertEqual(leaf.depth, 3); XCTAssertEqual(leaf.target, "origin/foo/bar")
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
            localExpanded: .constant(true), remoteExpanded: .constant(true), stashesExpanded: .constant(true), selection: .constant(nil),
            onAction: value.onAction, onRenameStash: { _ in }, onShortcut: { _ in false })
        coordinator.update(changed)
        XCTAssertTrue(coordinator.rows.contains { $0.id == "branch:feature/team/bar" && $0.current }, "A changed current branch must reveal its ancestors")
        let remoteIndex = try XCTUnwrap(coordinator.rows.firstIndex { $0.id == leaf.id })
        coordinator.activate(row: remoteIndex)
        XCTAssertEqual(actions.last, "refs/remotes/origin/foo/bar")
        let menu = try XCTUnwrap(coordinator.menu(row: remoteIndex))
        let copy = try XCTUnwrap(menu.items.first { ($0.representedObject as? NativeBranchTable.Coordinator.MenuAction)?.action == .copy })
        coordinator.performMenuAction(copy)
        XCTAssertEqual(actions.last, "origin/foo/bar")
        let button = NSButton(); button.identifier = .init("folder:remote:origin")
        coordinator.toggle(button)
        XCTAssertFalse(coordinator.rows.contains { $0.id == leaf.id })
        view = NativeBranchTable(branches: branches, stashes: [], repositoryPath: "/second", currentBranch: "feature/foo", isBusy: true,
            localExpanded: .constant(true), remoteExpanded: .constant(true), stashesExpanded: .constant(true), selection: .constant(nil),
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
        XCTAssertTrue(coordinator.setExpanded(row: 3, expanded: true), "Navigation remains available while busy")
        XCTAssertTrue(coordinator.rows.contains { $0.id == "remote:origin/main" })
    }

}
