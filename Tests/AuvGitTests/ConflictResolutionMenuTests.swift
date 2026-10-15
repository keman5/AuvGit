import AppKit
import SwiftUI
import Testing
import GitCore
@testable import AuvGit

@MainActor
struct ConflictResolutionMenuTests {
    @Test(arguments: ["UU", "AA", "DD", "AU", "UA", "DU", "UD"])
    func selectedConflictedFilesCanBeResolved(status: String) {
        let file = GitFile(path: "conflict.txt", indexStatus: String(status.prefix(1)), worktreeStatus: String(status.suffix(1)))
        let context = WorkspaceContextEligibility(paths: [file.path], files: [file], existing: [])
        #expect(context.canResolveConflicts)
        #expect(!context.canGit(.stage))
        let other = GitFile(path: "other.txt", indexStatus: "U", worktreeStatus: "U")
        #expect(WorkspaceContextEligibility(paths: [file.path, other.path], files: [file, other], existing: []).canResolveConflicts)
        #expect(!WorkspaceContextEligibility(paths: [file.path, "other"], files: [file], existing: []).canResolveConflicts)
        #expect(!WorkspaceContextEligibility(paths: [file.path, "normal.txt"], files: [file, GitFile(path: "normal.txt", indexStatus: "M", worktreeStatus: " ")], existing: []).canResolveConflicts)
        #expect(!WorkspaceContextEligibility(paths: [], files: [file], existing: []).canResolveConflicts)
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        store.repository = GitRepository(url: URL(fileURLWithPath: "/tmp/resolver-menu-fixture"))
        store.files = [file]; store.commitMessage = "Resolve"
        #expect(!store.canCommit)
        store.files = [GitFile(path: file.path, indexStatus: "M", worktreeStatus: " ")]
        #expect(store.canCommit)
    }

    @Test(arguments: [false, true])
    func nativeMenusOpenResolverForClickedConflict(tree: Bool) throws {
        _ = NSApplication.shared
        let file = GitFile(path: "conflict.txt", indexStatus: "U", worktreeStatus: "U")
        let repository = GitRepository(url: URL(fileURLWithPath: "/tmp/resolver-menu-fixture"))
        var invoked: FileAction?, clicked: Set<String> = []
        let action: (FileAction, Set<String>) -> Void = { invoked = $0; clicked = $1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        window.contentView = scroll
        let menu: NSMenu
        if tree {
            let view = WorkspaceTreeTable(rows: WorkspaceTreeRows.flatten([WorkspaceFileNode(path: file.path, isDirectory: false, children: [])], expanded: []),
                expanded: .constant([]), selection: .constant([]), repository: repository, files: [file], isBusy: false, openFile: { _ in }, onAction: action)
            let coordinator = view.makeCoordinator()
            let table = WorkspaceTreeTable.TreeTable(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
            table.coordinator = coordinator
            table.addTableColumn(NSTableColumn(identifier: .init("treeName")))
            table.dataSource = coordinator; table.delegate = coordinator; coordinator.table = table
            scroll.documentView = table
            coordinator.update(view)
            scroll.layoutSubtreeIfNeeded(); table.layoutSubtreeIfNeeded()
            let row = table.rect(ofRow: 0)
            let point = table.convert(NSPoint(x: row.midX, y: row.midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            menu = try #require(table.menu(for: event))
            let submenu = try #require(menu.items.first { $0.title == fileContextText("resolveConflict") }?.submenu)
            let item = try #require(submenu.items.first { $0.title == fileContextText("resolveOurs") })
            #expect(submenu.items.count == 3)
            #expect(item.isEnabled)
            #expect(NSApp.sendAction(try #require(item.action), to: coordinator, from: item))
            #expect(table.numberOfRows == 1)
        } else {
            let view = WorkspaceNativeFilesTable(rows: [WorkspaceFileRow(path: file.path, file: file)], files: [file], repository: repository,
                selection: .constant([]), isBusy: false, sortOrder: .constant([]), onAction: action, onCompare: { _ in })
            let coordinator = view.makeCoordinator()
            let table = WorkspaceNativeFilesTable.FileTable(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
            table.addTableColumn(NSTableColumn(identifier: .init("filename")))
            table.dataSource = coordinator; table.delegate = coordinator; coordinator.table = table
            scroll.documentView = table
            coordinator.update(view)
            scroll.layoutSubtreeIfNeeded(); table.layoutSubtreeIfNeeded()
            let row = table.rect(ofRow: 0)
            menu = try #require(coordinator.menu(at: NSPoint(x: row.midX, y: row.midY)))
            let submenu = try #require(menu.items.first { $0.title == fileContextText("resolveConflict") }?.submenu)
            let item = try #require(submenu.items.first { $0.title == fileContextText("resolveOurs") })
            #expect(submenu.items.count == 3)
            #expect(item.isEnabled)
            #expect(NSApp.sendAction(try #require(item.action), to: coordinator, from: item))
            #expect(table.numberOfRows == 1)
        }
        #expect(invoked == .resolveOurs)
        #expect(clicked == [file.path])
        #expect(menu.items.first { $0.title == fileContextText("stage") }?.isEnabled == false)
    }

    @Test(arguments: [false, true])
    func nativeMenusResolveAllSelectedConflicts(tree: Bool) throws {
        _ = NSApplication.shared
        let files = ["one.txt", "two.txt"].map { GitFile(path: $0, indexStatus: "U", worktreeStatus: "U") }
        let repository = GitRepository(url: URL(fileURLWithPath: "/tmp/resolver-menu-fixture"))
        var invoked: FileAction?, clicked: Set<String> = []
        let action: (FileAction, Set<String>) -> Void = { invoked = $0; clicked = $1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        window.contentView = scroll
        let menu: NSMenu
        let coordinator: NSObject
        if tree {
            let nodes = files.map { WorkspaceFileNode(path: $0.path, isDirectory: false, children: []) }
            let view = WorkspaceTreeTable(rows: WorkspaceTreeRows.flatten(nodes, expanded: []), expanded: .constant([]), selection: .constant([]), repository: repository, files: files, isBusy: false, openFile: { _ in }, onAction: action)
            let owner = view.makeCoordinator()
            let table = WorkspaceTreeTable.TreeTable(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
            table.coordinator = owner; table.addTableColumn(NSTableColumn(identifier: .init("treeName")))
            table.dataSource = owner; table.delegate = owner; owner.table = table; scroll.documentView = table; owner.update(view)
            table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
            menu = try #require(owner.menu(at: NSPoint(x: 10, y: table.rect(ofRow: 0).midY)))
            coordinator = owner
        } else {
            let rows = files.map { WorkspaceFileRow(path: $0.path, file: $0) }
            let view = WorkspaceNativeFilesTable(rows: rows, files: files, repository: repository, selection: .constant([]), isBusy: false, sortOrder: .constant([]), onAction: action, onCompare: { _ in })
            let owner = view.makeCoordinator()
            let table = WorkspaceNativeFilesTable.FileTable(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
            table.coordinator = owner; table.addTableColumn(NSTableColumn(identifier: .init("filename")))
            table.dataSource = owner; table.delegate = owner; owner.table = table; scroll.documentView = table; owner.update(view)
            table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
            menu = try #require(owner.menu(at: NSPoint(x: 10, y: table.rect(ofRow: 0).midY)))
            coordinator = owner
        }
        let submenu = try #require(menu.items.first { $0.title == fileContextText("resolveConflict") }?.submenu)
        #expect(submenu.items.count == 3)
        let item = try #require(submenu.items.first { $0.title == fileContextText("resolveTheirs") })
        #expect(NSApp.sendAction(try #require(item.action), to: coordinator, from: item))
        #expect(invoked == .resolveTheirs)
        #expect(clicked == Set(files.map(\.path)))
    }

    @Test func oneOrMoreRecoverableResolvedFilesOfferRecreate() {
        let first = GitFile(path: "first", indexStatus: "M", worktreeStatus: " ")
        let second = GitFile(path: "second", indexStatus: "M", worktreeStatus: " ")
        let recreatable: Set<String> = [first.path, second.path]
        #expect(WorkspaceContextEligibility(paths: [first.path], files: [first], existing: [first.path], recreatableConflicts: recreatable).canRecreateConflict)
        #expect(WorkspaceContextEligibility(paths: [first.path, second.path], files: [first, second], existing: [first.path, second.path], recreatableConflicts: recreatable).canRecreateConflict)
        #expect(!WorkspaceContextEligibility(paths: [first.path, "other"], files: [first], existing: [first.path], recreatableConflicts: recreatable).canRecreateConflict)
        #expect(!WorkspaceContextEligibility(paths: [first.path, second.path], files: [first, second], existing: [], recreatableConflicts: [first.path]).canRecreateConflict)
        let conflict = GitFile(path: second.path, indexStatus: "U", worktreeStatus: "U")
        #expect(!WorkspaceContextEligibility(paths: [first.path, second.path], files: [first, conflict], existing: [], recreatableConflicts: recreatable).canRecreateConflict)
        #expect(!WorkspaceContextEligibility(paths: [], files: [first], existing: [], recreatableConflicts: recreatable).canRecreateConflict)
    }

    @Test(arguments: [false, true])
    func nativeMenusRecreateMultipleResolvedConflicts(tree: Bool) throws {
        _ = NSApplication.shared
        let files = ["one.txt", "two.txt"].map { GitFile(path: $0, indexStatus: "M", worktreeStatus: " ") }
        let paths = Set(files.map(\.path))
        let repository = GitRepository(url: URL(fileURLWithPath: "/tmp/resolver-menu-fixture"))
        var invoked: FileAction?, clicked: Set<String> = []
        let action: (FileAction, Set<String>) -> Void = { invoked = $0; clicked = $1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        window.contentView = scroll
        let menu: NSMenu
        let coordinator: NSObject
        if tree {
            let nodes = files.map { WorkspaceFileNode(path: $0.path, isDirectory: false, children: []) }
            let view = WorkspaceTreeTable(rows: WorkspaceTreeRows.flatten(nodes, expanded: []), expanded: .constant([]), selection: .constant([]), repository: repository, files: files, isBusy: false, openFile: { _ in }, onAction: action, recreatableConflicts: paths)
            let owner = view.makeCoordinator()
            let table = WorkspaceTreeTable.TreeTable(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
            table.coordinator = owner; table.addTableColumn(NSTableColumn(identifier: .init("treeName")))
            table.dataSource = owner; table.delegate = owner; owner.table = table; scroll.documentView = table; owner.update(view)
            table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
            menu = try #require(owner.menu(at: NSPoint(x: 10, y: table.rect(ofRow: 0).midY)))
            coordinator = owner
        } else {
            let rows = files.map { WorkspaceFileRow(path: $0.path, file: $0) }
            let view = WorkspaceNativeFilesTable(rows: rows, files: files, repository: repository, selection: .constant([]), isBusy: false, sortOrder: .constant([]), onAction: action, onCompare: { _ in }, recreatableConflicts: paths)
            let owner = view.makeCoordinator()
            let table = WorkspaceNativeFilesTable.FileTable(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
            table.coordinator = owner; table.addTableColumn(NSTableColumn(identifier: .init("filename")))
            table.dataSource = owner; table.delegate = owner; owner.table = table; scroll.documentView = table; owner.update(view)
            table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
            menu = try #require(owner.menu(at: NSPoint(x: 10, y: table.rect(ofRow: 0).midY)))
            coordinator = owner
        }
        let item = try #require(menu.items.first { $0.title == fileContextText("recreateConflict") })
        #expect(NSApp.sendAction(try #require(item.action), to: coordinator, from: item))
        #expect(invoked == .recreateConflict)
        #expect(clicked == paths)
    }
}
