import XCTest
import GitCore
@testable import RayGit

final class WorkspaceFileActionTargetsTests: XCTestCase {
    private let files = [
        GitFile(path: "modified", indexStatus: " ", worktreeStatus: "M"),
        GitFile(path: "staged", indexStatus: "M", worktreeStatus: " "),
        GitFile(path: "mixed", indexStatus: "M", worktreeStatus: "M"),
        GitFile(path: "untracked", indexStatus: "?", worktreeStatus: "?"),
        GitFile(path: "conflict", indexStatus: "U", worktreeStatus: "U")
    ]
    func testEmptySelectionTargetsAllEligibleRows() {
        XCTAssertEqual(WorkspaceFileActionTargets.paths(for: .stage, files: files, selection: []), ["modified", "mixed", "untracked"])
        XCTAssertEqual(WorkspaceFileActionTargets.paths(for: .unstage, files: files, selection: []), ["staged", "mixed"])
        XCTAssertEqual(WorkspaceFileActionTargets.paths(for: .discard, files: files, selection: []), ["modified", "mixed", "untracked"])
    }
    func testSelectionRestrictsTargetsWithoutFallingBackToAll() {
        XCTAssertEqual(WorkspaceFileActionTargets.paths(for: .discard, files: files, selection: ["modified", "untracked", "conflict"]), ["modified", "untracked"])
        XCTAssertEqual(WorkspaceFileActionTargets.paths(for: .stage, files: files, selection: ["missing", "ignored"]), [])
        XCTAssertEqual(WorkspaceFileActionTargets.paths(for: .unstage, files: files, selection: ["modified"]), [])
    }
    func testCleanRepositoryAndConflictsNeverProduceDiscardTargets() {
        XCTAssertTrue(WorkspaceFileActionTargets.paths(for: .discard, files: [], selection: []).isEmpty)
        XCTAssertTrue(WorkspaceFileActionTargets.paths(for: .discard, files: files, selection: ["conflict"]).isEmpty)
    }
    func testAvailabilityMatchesResolvedTargetsForStatusesAndSelections() {
        let rows = files + [GitFile(path: "ignored", indexStatus: "!", worktreeStatus: "!"), GitFile(path: "clean", indexStatus: " ", worktreeStatus: " ")]
        let selections: [Set<String>] = [[], ["modified"], ["staged"], ["mixed"], ["untracked"], ["conflict"], ["ignored"], ["clean"], ["missing"], ["missing", "ignored"], ["conflict", "mixed", "untracked"]]
        for action in [FileAction.stage, .stageAll, .unstage, .unstageAll, .discard, .compare] {
            for selection in selections {
                XCTAssertEqual(WorkspaceFileActionTargets.hasEligibleTarget(for: action, files: rows, selection: selection), !WorkspaceFileActionTargets.paths(for: action, files: rows, selection: selection).isEmpty, "Availability must match resolved targets for \(action), \(selection)")
            }
            XCTAssertFalse(WorkspaceFileActionTargets.hasEligibleTarget(for: action, files: [], selection: []))
        }
    }
}
