import XCTest
import GitCore
@testable import AuvGit

@MainActor
final class WorkspaceFileStatusTests: XCTestCase {
    private func file(_ index: String, _ worktree: String, _ path: String = "file") -> GitFile {
        GitFile(path: path, indexStatus: index, worktreeStatus: worktree)
    }
    func testPorcelainIndexDoesNotHideWorkingTreeChanges() {
        XCTAssertEqual(WorkspaceFileStatus(file("M", " ")).keys, ["stagedStatus"])
        XCTAssertEqual(WorkspaceFileStatus(file("M", "M")).keys, ["stagedStatus", "modified"])
        XCTAssertEqual(WorkspaceFileStatus(file("A", "D")).keys, ["stagedStatus", "deleted"])
        XCTAssertEqual(WorkspaceFileStatus(file("D", " ")).keys, ["stagedStatus", "deleted"])
        XCTAssertEqual(WorkspaceFileStatus(file(" ", "D")).keys, ["deleted"])
        XCTAssertEqual(WorkspaceFileStatus(file("?", "?")).keys, ["untracked"])
        XCTAssertEqual(WorkspaceFileStatus(file("A", "A")).keys, ["conflict"])
    }
    func testGlobalTargetsRetainGitEligibilityWhenSelectionIsNotInScope() {
        let files = [file("M", " ", "staged"), file(" ", "M", "modified"), file("?", "?", "new"), file("U", "U", "conflict")]
        XCTAssertEqual(WorkspaceFileActionTargets.paths(for: .stage, files: files, selection: []), ["modified", "new"])
        XCTAssertEqual(WorkspaceFileActionTargets.paths(for: .unstage, files: files, selection: []), ["staged"])
        XCTAssertEqual(WorkspaceFileActionTargets.paths(for: .discard, files: files, selection: []), ["modified", "new", "conflict"])
        XCTAssertEqual(WorkspaceFileActionTargets.paths(for: .stage, files: files, selection: ["modified"]), ["modified"])
        XCTAssertEqual(WorkspaceFileActionTargets.paths(for: .stage, files: files, selection: ["ignored"]), [])
    }
}

@MainActor
final class WorkspaceTreeSelectionTests: XCTestCase {
    func testDirectoryExpandsOnlyChangedDescendants() {
        XCTAssertEqual(WorkspaceTreeSelection.resolve(["src"], changedPaths: ["src/a", "src/nested/b", "src-old/c", "README"]), ["src/a", "src/nested/b"])
    }
    func testEmptyDirectoryDoesNotBecomeGlobalScope() {
        let selected = WorkspaceTreeSelection.resolve(["clean-directory"], changedPaths: ["other/file"])
        XCTAssertEqual(selected, ["clean-directory"])
        let files = [GitFile(path: "other/file", indexStatus: " ", worktreeStatus: "M")]
        XCTAssertTrue(WorkspaceFileActionTargets.paths(for: .stage, files: files, selection: selected).isEmpty)
    }
    func testMixedFileAndDirectorySelection() {
        XCTAssertEqual(WorkspaceTreeSelection.resolve(["src", "README"], changedPaths: ["src/a", "README", "other"]), ["src/a", "README"])
    }
}
