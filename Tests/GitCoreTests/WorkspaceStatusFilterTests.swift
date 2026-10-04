import XCTest
@testable import GitCore

final class WorkspaceStatusFilterTests: XCTestCase {
    func testUntrackedAndAddedAreSeparate() {
        let untracked = GitFile(path: "new", indexStatus: "?", worktreeStatus: "?")
        let added = GitFile(path: "added", indexStatus: "A", worktreeStatus: " ")
        XCTAssertTrue(WorkspaceStatusFilter.untracked.includes(untracked))
        XCTAssertFalse(WorkspaceStatusFilter.added.includes(untracked))
        XCTAssertTrue(WorkspaceStatusFilter.added.includes(added))
        XCTAssertFalse(WorkspaceStatusFilter.untracked.includes(added))
    }
    func testMixedStatusesAndConflicts() {
        let renamedAndModified = GitFile(path: "new", indexStatus: "R", worktreeStatus: "M")
        XCTAssertTrue(WorkspaceStatusFilter.renamed.includes(renamedAndModified))
        XCTAssertTrue(WorkspaceStatusFilter.modified.includes(renamedAndModified))
        XCTAssertTrue(WorkspaceStatusFilter.staged.includes(renamedAndModified))
        for pair in [("U", "U"), ("A", "A"), ("D", "D")] {
            let conflict = GitFile(path: "conflict", indexStatus: pair.0, worktreeStatus: pair.1)
            XCTAssertTrue(WorkspaceStatusFilter.conflict.includes(conflict))
            for filter in WorkspaceStatusFilter.allCases where filter != .all && filter != .conflict {
                XCTAssertFalse(filter.includes(conflict))
            }
        }
    }
    func testHiddenComponents() {
        XCTAssertTrue(WorkspaceStatusFilter.isHiddenPath(".env"))
        XCTAssertTrue(WorkspaceStatusFilter.isHiddenPath("src/.cache/file"))
        XCTAssertFalse(WorkspaceStatusFilter.isHiddenPath("src/file.swift"))
    }
}
