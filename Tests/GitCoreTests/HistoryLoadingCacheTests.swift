import XCTest
@testable import GitCore

final class HistoryLoadingCacheTests: XCTestCase {
    func testFilePaginationAndFiltersShareRenameTraversalAndInvalidateAfterCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await fixture(root)
        try "first\n".write(to: root.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["old.txt"]); try await repo.commit(message: "origin")
        try "first\nsecond\n".write(to: root.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["old.txt"]); try await repo.commit(message: "edited")
        _ = try await repo.workflowRead(["mv", "old.txt", "new.txt"])
        try await repo.commit(message: "renamed")

        let first = try await repo.log(limit: 1, path: "new.txt")
        let second = try await repo.log(limit: 1, skip: 1, path: "new.txt")
        let filtered = try await repo.log(search: "origin", path: "new.txt", author: "Fixture")
        XCTAssertEqual(first.map(\.subject), ["renamed"])
        XCTAssertEqual(second.map(\.subject), ["edited"])
        XCTAssertEqual(filtered.map(\.subject), ["origin"])
        let warmCount = await repo.fileHistoryTraversalCount
        XCTAssertEqual(warmCount, 1, "Paging and filtering must not repeat --follow traversal")

        try "third\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["new.txt"]); try await repo.commit(message: "latest")
        let refreshed = try await repo.log(limit: 1, path: "new.txt")
        XCTAssertEqual(refreshed.first?.subject, "latest")
        let refreshedCount = await repo.fileHistoryTraversalCount
        XCTAssertEqual(refreshedCount, 2)
    }

    func testPublicationTraversalIsSharedAcrossPagesAndInvalidatesForRemoteChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await fixture(root)
        for index in 0..<3 { _ = try await repo.workflowRead(["commit", "--allow-empty", "-m", "commit \(index)"]) }
        _ = try await repo.workflowRead(["update-ref", "refs/remotes/origin/main", "HEAD~1"])
        let commits = try await repo.log(ref: "HEAD")
        let first = try await repo.unpublishedCommitHashes(in: Array(commits.prefix(1)))
        let second = try await repo.unpublishedCommitHashes(in: commits)
        XCTAssertEqual(first, Set(commits.prefix(1).map(\.hash)))
        XCTAssertEqual(second, first)
        let warmCount = await repo.publicationTraversalCount
        XCTAssertEqual(warmCount, 1)
        _ = try await repo.workflowRead(["update-ref", "refs/remotes/origin/main", "HEAD"])
        let published = try await repo.unpublishedCommitHashes(in: commits)
        XCTAssertTrue(published.isEmpty)
        let refreshedCount = await repo.publicationTraversalCount
        XCTAssertEqual(refreshedCount, 2)
        _ = try await repo.workflowRead(["checkout", "--detach", "HEAD"])
        _ = try await repo.workflowRead(["commit", "--allow-empty", "-m", "detached"])
        let detached = try await repo.log(ref: "HEAD")
        let outgoing = try await repo.unpublishedCommitHashes(in: detached)
        XCTAssertEqual(outgoing, Set(detached.prefix(1).map(\.hash)))
    }

    private func fixture(_ root: URL) async throws -> GitRepository {
        let repo = try await GitRepository.initialize(at: root)
        for args in [["config", "user.name", "Fixture"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"]] {
            _ = try await repo.workflowRead(args)
        }
        return repo
    }

    func testReflogSelectorInvalidatesEvenWhenOrdinaryRefsReturnToSameHashes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await fixture(root)
        for index in 0..<2 {
            try "version \(index)\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            try await repo.stage(paths: ["file.txt"]); try await repo.commit(message: "version \(index)")
        }
        let head = try await repo.workflowRevision("HEAD")
        let tree = try await repo.workflowRead(["rev-parse", "HEAD^{tree}"]).trimmingCharacters(in: .newlines)
        let alternate = try await repo.workflowRead(["commit-tree", tree, "-p", head, "-m", "alternate"]).trimmingCharacters(in: .newlines)
        let before = try await repo.log(path: "file.txt", ref: "HEAD@{1}")
        XCTAssertEqual(before.first?.subject, "version 0")
        _ = try await repo.workflowRead(["reset", "--hard", alternate])
        _ = try await repo.workflowRead(["reset", "--hard", head])
        let after = try await repo.log(path: "file.txt", ref: "HEAD@{1}")
        // The alternate commit has the same file tree as version 1, whose change
        // must now be reachable through the previous HEAD reflog entry.
        XCTAssertEqual(after.first?.subject, "version 1")
        let traversals = await repo.fileHistoryTraversalCount
        XCTAssertEqual(traversals, 2)
    }

    func testSwitchingBranchesAtSameCommitRefreshesHeadDecoration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await fixture(root)
        try "content\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file.txt"]); try await repo.commit(message: "base")
        let original = try await repo.currentBranch()
        _ = try await repo.workflowRead(["branch", "other-branch"])
        let before = try await repo.log(path: "file.txt", ref: "HEAD")
        XCTAssertTrue(before.first?.refs.contains("HEAD -> " + original) == true)
        try await repo.checkout(branch: "other-branch")
        let after = try await repo.log(path: "file.txt", ref: "HEAD")
        XCTAssertTrue(after.first?.refs.contains("HEAD -> other-branch") == true)
        let traversals = await repo.fileHistoryTraversalCount
        XCTAssertEqual(traversals, 2)
    }
}
