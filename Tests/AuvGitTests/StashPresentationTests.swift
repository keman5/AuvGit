import XCTest
import SwiftUI
import GitCore
@testable import AuvGit

@MainActor
final class StashPresentationTests: XCTestCase {
    func testSidebarPrefixesCreationTimeAndPreservesActionReference() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let stash = GitStash(ref: "stash@{0}", subject: "Saved work", createdDate: date)
        let pane = NativeBranchTable(branches: [], stashes: [stash], repositoryPath: "/fixture", currentBranch: "main", isBusy: false,
            localExpanded: .constant(true), stashesExpanded: .constant(true), selection: .constant(nil),
            onAction: { _, _ in }, onRenameStash: { _ in }, onShortcut: { _ in false })
        let row = try XCTUnwrap(pane.rows.first { $0.id == "stash:stash@{0}" })
        XCTAssertEqual(row.title, HistoryCalendarDate.text(date) + " · Saved work")
        XCTAssertEqual(row.target, "stash@{0}")
        XCTAssertEqual(GitStash(ref: "stash@{1}", subject: "Older cache").datedTitle, "Older cache")
    }
}
