import XCTest
@testable import GitCore

final class AICommitInputTests: XCTestCase {
    func testWorkspaceIncludesEveryChangeLayerWithoutStagingOrReadingIgnoredFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await GitRepository.initialize(at: root)
        func write(_ path: String, _ text: String) throws {
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }
        try write("shared.txt", "BASE\n")
        try write("unchanged.txt", "UNCHANGED_PRIVATE\n")
        try write(".gitignore", "ignored.txt\n")
        _ = try await repository.workflowRead(["add", "."])
        _ = try await repository.workflowRead(["-c", "user.name=QA", "-c", "user.email=qa@example.test", "-c", "commit.gpgSign=false", "commit", "-m", "Initial"])
        try write("shared.txt", "INDEX_CHANGE\n")
        _ = try await repository.workflowRead(["add", "shared.txt"])
        try write("shared.txt", "WORKTREE_CHANGE\n")
        try write("new file.txt", "UNTRACKED_CHANGE\n")
        try write("empty.txt", "")
        try write("ignored.txt", "IGNORED_PRIVATE\n")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link.txt").path, withDestinationPath: "ignored.txt")
        let before = try await repository.workflowRead(["ls-files", "--stage", "-z"])
        let staged = try await repository.aiCommitInput(scope: .staged, summaryOnly: false, maximumBytes: 10_000)
        XCTAssertTrue(staged.contains("INDEX_CHANGE"))
        XCTAssertFalse(staged.contains("WORKTREE_CHANGE"))
        XCTAssertFalse(staged.contains("UNTRACKED_CHANGE"))
        let all = try await repository.aiCommitInput(scope: .workspace, summaryOnly: false, maximumBytes: 10_000)
        for marker in ["INDEX_CHANGE", "WORKTREE_CHANGE", "UNTRACKED_CHANGE", "empty.txt", "link.txt"] { XCTAssertTrue(all.contains(marker), marker) }
        for marker in ["IGNORED_PRIVATE", "UNCHANGED_PRIVATE"] { XCTAssertFalse(all.contains(marker), marker) }
        let summary = try await repository.aiCommitInput(scope: .workspace, summaryOnly: true, maximumBytes: 10_000)
        XCTAssertTrue(summary.contains("new file.txt"))
        XCTAssertFalse(summary.contains("UNTRACKED_CHANGE"))
        do {
            _ = try await repository.aiCommitInput(scope: .workspace, summaryOnly: false, maximumBytes: all.utf8.count - 1)
            XCTFail("The combined input must obey one budget")
        } catch AICommitInputError.exceedsLimit {}
        let after = try await repository.workflowRead(["ls-files", "--stage", "-z"])
        XCTAssertEqual(before, after)
    }

    func testBoundedReadRejectsPartialPatchAndAllowsExplicitLargerLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await GitRepository.initialize(at: root)
        try Data(String(repeating: "staged content\n", count: 200).utf8).write(to: root.appendingPathComponent("staged.txt"))
        _ = try await repository.workflowRead(["add", "staged.txt"])
        let arguments = ["diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-color"]
        do {
            _ = try await repository.aiCommitRead(arguments, maximumBytes: 100)
            XCTFail("Partial patch must not be returned")
        } catch AICommitInputError.exceedsLimit {}
        let patch = try await repository.aiCommitRead(arguments, maximumBytes: 10_000)
        XCTAssertTrue(patch.contains("staged content"))
        let exact = try await repository.aiCommitRead(arguments, maximumBytes: patch.utf8.count)
        XCTAssertEqual(exact, patch)
        let status = try await repository.aiCommitRead(["diff", "--cached", "--name-status"], maximumBytes: 100)
        XCTAssertTrue(status.contains("staged.txt"))
        XCTAssertFalse(status.contains("staged content"))
    }
}
