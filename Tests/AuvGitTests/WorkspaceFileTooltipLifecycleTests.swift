import AppKit
import SwiftUI
import XCTest
import GitCore
import AuvGitLocalization
@testable import AuvGit

/// Exercise hover lifecycle without showing a window or moving the system pointer.
@MainActor
final class WorkspaceFileTooltipLifecycleTests: XCTestCase {
    func testCommitRevokesStationaryTooltipsBeforePreparedRowsAreCleared() throws {
        _ = NSApplication.shared
        let file = GitFile(path: "src/committed.swift", indexStatus: "M", worktreeStatus: " ")
        var parent = model(file)
        let coordinator = parent.makeCoordinator()
        let table = WorkspaceNativeFilesTable.FileTable()
        table.coordinator = coordinator
        for name in ["filename", "status", "directory"] {
            let column = NSTableColumn(identifier: .init(name)); column.width = 150
            table.addTableColumn(column)
        }
        table.dataSource = coordinator; coordinator.table = table
        coordinator.update(parent)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 450, height: 200))
        scroll.documentView = table
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.close() }
        scroll.layoutSubtreeIfNeeded(); table.updateTrackingAreas()
        let point = NSPoint(x: 20, y: table.rect(ofRow: 0).midY)
        let oldTag = try XCTUnwrap(table.fileToolTipTags.first)
        let oldOwner = try XCTUnwrap(table.fileToolTipOwner)

        parent = WorkspaceNativeFilesTable(rows: parent.rows, files: parent.files, repository: parent.repository,
            selection: .constant([]), isBusy: true, sortOrder: .constant([]), onAction: { _, _ in }, onCompare: { _ in })
        coordinator.update(parent)
        table.updateTrackingAreas()
        XCTAssertTrue(table.fileToolTipTags.isEmpty)
        XCTAssertEqual(oldOwner.view(table, stringForToolTip: oldTag, point: point, userData: nil), "")
        for column in table.tableColumns { XCTAssertNil(table.fileToolTip(row: 0, column: column)) }

        // Git has finished, but asynchronous row preparation still holds the old row.
        parent = WorkspaceNativeFilesTable(rows: parent.rows, files: [], repository: parent.repository,
            selection: .constant([]), isBusy: false, sortOrder: .constant([]), onAction: { _, _ in }, onCompare: { _ in })
        coordinator.update(parent)
        for column in table.tableColumns { XCTAssertNil(table.fileToolTip(row: 0, column: column)) }
        XCTAssertFalse(window.isVisible)
    }

    func testChangedSourceStatusCannotUseAnOlderPreparedRow() {
        let before = GitFile(path: "src/file.swift", indexStatus: "M", worktreeStatus: " ")
        let parent = model(before)
        let coordinator = parent.makeCoordinator()
        let table = WorkspaceNativeFilesTable.FileTable()
        table.coordinator = coordinator; table.dataSource = coordinator; coordinator.table = table
        coordinator.update(parent)
        let after = GitFile(path: before.path, indexStatus: " ", worktreeStatus: "M")
        let stale = WorkspaceNativeFilesTable(rows: parent.rows, files: [after], repository: parent.repository,
            selection: .constant([]), isBusy: false, sortOrder: .constant([]), onAction: { _, _ in }, onCompare: { _ in })
        coordinator.update(stale)
        let status = NSTableColumn(identifier: .init("status"))
        XCTAssertNil(table.fileToolTip(row: 0, column: status))
        coordinator.update(model(after))
        XCTAssertEqual(table.fileToolTip(row: 0, column: status), statusText(after))
    }

    func testPreparingRowsRevokesPendingTooltipsWithoutReloadingOrMovingPointer() throws {
        _ = NSApplication.shared
        let file = GitFile(path: "src/committed.swift", indexStatus: "M", worktreeStatus: " ")
        var parent = model(file)
        let coordinator = parent.makeCoordinator()
        let table = WorkspaceNativeFilesTable.FileTable()
        table.coordinator = coordinator
        let column = NSTableColumn(identifier: .init("filename")); column.width = 400
        table.addTableColumn(column)
        table.dataSource = coordinator; table.delegate = coordinator; coordinator.table = table
        coordinator.update(parent)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.documentView = table
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.close() }
        scroll.layoutSubtreeIfNeeded(); table.updateTrackingAreas()
        let point = NSPoint(x: 20, y: table.rect(ofRow: 0).midY)
        let oldTag = try XCTUnwrap(table.fileToolTipTags.first)
        let oldOwner = try XCTUnwrap(table.fileToolTipOwner)
        XCTAssertEqual(table.view(table, stringForToolTip: oldTag, point: point, userData: nil), "committed.swift")

        // The prepared rows intentionally stay visible during an asynchronous refresh.
        parent.isReady = false
        coordinator.update(parent)
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertTrue(table.fileToolTipTags.isEmpty)
        table.updateTrackingAreas()
        XCTAssertTrue(table.fileToolTipTags.isEmpty)
        XCTAssertEqual(table.view(table, stringForToolTip: oldTag, point: point, userData: nil), "")

        parent.isReady = true
        coordinator.update(parent)
        let newTag = try XCTUnwrap(table.fileToolTipTags.first)
        let newOwner = try XCTUnwrap(table.fileToolTipOwner)
        XCTAssertFalse(oldOwner === newOwner)
        // Numeric tags may be reused; the old owner must reject even a current tag.
        XCTAssertEqual(oldOwner.view(table, stringForToolTip: newTag, point: point, userData: nil), "")
        XCTAssertEqual(table.view(table, stringForToolTip: newTag, point: point, userData: nil), "committed.swift")
        XCTAssertFalse(window.isVisible)
    }

    func testStatusTooltipsReadCurrentModelWithoutMaterializedOrReusedCells() {
        let before = GitFile(path: "src/file.swift", indexStatus: "M", worktreeStatus: " ")
        let parent = model(before)
        let coordinator = parent.makeCoordinator()
        let table = WorkspaceNativeFilesTable.FileTable()
        table.coordinator = coordinator; table.dataSource = coordinator; coordinator.table = table
        coordinator.update(parent)
        let status = NSTableColumn(identifier: .init("status"))
        let index = NSTableColumn(identifier: .init("index"))
        XCTAssertEqual(table.fileToolTip(row: 0, column: status), statusText(before))
        XCTAssertEqual(table.fileToolTip(row: 0, column: index), L10n.text("modified", table: "Files"))

        let after = GitFile(path: before.path, indexStatus: " ", worktreeStatus: "M")
        coordinator.update(model(after))
        XCTAssertEqual(table.fileToolTip(row: 0, column: status), statusText(after))
        XCTAssertEqual(table.fileToolTip(row: 0, column: index), L10n.text("none", table: "Files"))
        coordinator.update(WorkspaceNativeFilesTable(rows: [], files: [], repository: parent.repository,
            selection: .constant([]), isBusy: false, sortOrder: .constant([]), onAction: { _, _ in }, onCompare: { _ in }))
        XCTAssertNil(table.fileToolTip(row: 0, column: status))
        XCTAssertNil(table.fileToolTip(row: 0, column: index))
    }

    private func model(_ file: GitFile) -> WorkspaceNativeFilesTable {
        WorkspaceNativeFilesTable(rows: [.init(path: file.path, file: file)], files: [file],
            repository: GitRepository(url: URL(fileURLWithPath: "/tmp/auvgit-tooltip-lifecycle")),
            selection: .constant([]), isBusy: false, sortOrder: .constant([]),
            onAction: { _, _ in }, onCompare: { _ in })
    }

    private func statusText(_ file: GitFile) -> String {
        WorkspaceFileStatus(file).keys.map { L10n.text($0, table: "Files") }.joined(separator: " · ")
    }
}
