import XCTest
import GitCore
@testable import RayGit

final class WorkspaceContextEligibilityTests: XCTestCase {
    private let files = [GitFile(path: "tracked", indexStatus: " ", worktreeStatus: "M"), GitFile(path: "new", indexStatus: "?", worktreeStatus: "?")]
    func testIgnoreRequiresEveryClickedPathToBeUntrackedAndPresent() {
        XCTAssertTrue(WorkspaceContextEligibility(paths: ["new"], files: files, existing: ["new"]).canIgnore)
        XCTAssertFalse(WorkspaceContextEligibility(paths: ["tracked", "new"], files: files, existing: ["tracked", "new"]).canIgnore)
        XCTAssertFalse(WorkspaceContextEligibility(paths: ["new"], files: files, existing: []).canIgnore)
        XCTAssertFalse(WorkspaceContextEligibility(paths: ["ignored"], files: files, existing: ["ignored"]).canIgnore)
    }
    func testCleanTreeFileHistoryDoesNotRequireChangedStatusRow() {
        let clean = WorkspaceContextEligibility(paths: ["clean"], files: files, existing: ["clean"])
        XCTAssertTrue(clean.canHistory(allowCleanFile: true))
        XCTAssertFalse(clean.canHistory(allowCleanFile: false))
        XCTAssertFalse(WorkspaceContextEligibility(paths: ["new"], files: files, existing: ["new"]).canHistory(allowCleanFile: true))
        XCTAssertFalse(WorkspaceContextEligibility(paths: ["missing"], files: files, existing: []).canHistory(allowCleanFile: true))
        let added = [GitFile(path: "added", indexStatus: "A", worktreeStatus: " ")]
        XCTAssertFalse(WorkspaceContextEligibility(paths: ["added"], files: added, existing: ["added"]).canHistory(allowCleanFile: true))
    }
    func testEmptyOrMixedContextDoesNotBecomeGlobalGitAction() {
        XCTAssertFalse(WorkspaceContextEligibility(paths: [], files: files, existing: []).canGit(.stage))
        XCTAssertFalse(WorkspaceContextEligibility(paths: ["tracked", "ignored"], files: files, existing: ["tracked", "ignored"]).canGit(.stage))
        XCTAssertTrue(WorkspaceContextEligibility(paths: ["new"], files: files, existing: ["new"]).canGit(.stage))
    }
}
