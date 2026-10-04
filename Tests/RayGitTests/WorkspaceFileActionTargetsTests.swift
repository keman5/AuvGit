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
        XCTAssertEqual(WorkspaceFileActionTargets.paths(for: .discard, files: files, selection: []), ["modified", "mixed"])
    }
    func testSelectionRestrictsTargetsWithoutFallingBackToAll() {
        XCTAssertEqual(WorkspaceFileActionTargets.paths(for: .discard, files: files, selection: ["modified", "untracked", "conflict"]), ["modified"])
        XCTAssertEqual(WorkspaceFileActionTargets.paths(for: .stage, files: files, selection: ["missing", "ignored"]), [])
        XCTAssertEqual(WorkspaceFileActionTargets.paths(for: .unstage, files: files, selection: ["modified"]), [])
    }
    func testCleanRepositoryAndConflictsNeverProduceDiscardTargets() {
        XCTAssertTrue(WorkspaceFileActionTargets.paths(for: .discard, files: [], selection: []).isEmpty)
        XCTAssertTrue(WorkspaceFileActionTargets.paths(for: .discard, files: files, selection: ["untracked", "conflict"]).isEmpty)
    }
}
