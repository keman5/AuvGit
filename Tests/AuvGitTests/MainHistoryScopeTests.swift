import XCTest
@testable import AuvGit
@testable import GitCore

@MainActor
final class MainHistoryScopeTests: XCTestCase {
    private func fixture() async throws -> (URL, GitRepository, String, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = GitRepository(url: root)
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"]] {
            _ = try await GitProcess.run(at: root, arguments: args)
        }
        func commit(_ name: String) async throws {
            try name.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
            try await repo.stage(paths: [name]); try await repo.commit(message: name)
        }
        try await commit("base")
        _ = try await GitProcess.run(at: root, arguments: ["checkout", "-b", "side"])
        try await commit("side")
        let side = try await repo.workflowRevision("HEAD")
        _ = try await GitProcess.run(at: root, arguments: ["checkout", "main"])
        try await commit("main")
        _ = try await GitProcess.run(at: root, arguments: ["merge", "--no-ff", "side", "-m", "merge"])
        _ = try await GitProcess.run(at: root, arguments: ["checkout", "-b", "unrelated", "main~2"])
        try await commit("unrelated")
        let unrelated = try await repo.workflowRevision("HEAD")
        _ = try await GitProcess.run(at: root, arguments: ["checkout", "main"])
        return (root, repo, side, unrelated)
    }
    func testMainFollowsHEADFirstParentAndIgnoresStaleRefPathAndSelection() async throws {
        let (root, repo, side, unrelated) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        defer { store.closeTransientSession() }
        await store.open(root)
        let expected = try await repo.log(ref: "HEAD", firstParent: true)
        XCTAssertEqual(store.commits.map(\.hash), expected.map(\.hash))
        XCTAssertFalse(store.commits.contains { $0.hash == side || $0.hash == unrelated })
        XCTAssertEqual(CommitGraph(commits: store.commits, firstParent: true).laneCount, 1)
        XCTAssertEqual(store.commits.first?.parents.count, 2)
        store.historyRef = "unrelated"; store.historyPath = "unrelated"; store.selectedCommit = unrelated
        await store.loadHistory(reset: true)
        XCTAssertEqual(store.commits.map(\.hash), expected.map(\.hash))
        XCTAssertNil(store.selectedCommit)
        store.showMergedCommits = true
        await store.loadHistory(reset: true)
        XCTAssertTrue(store.commits.contains { $0.hash == side })
        XCTAssertFalse(store.commits.contains { $0.hash == unrelated })
        let independent = try await repo.log()
        XCTAssertTrue(independent.contains { $0.hash == unrelated })
    }
    func testExternalBranchSwitchResetsSelectionNavigationAndMainScope() async throws {
        let (root, repo, _, unrelated) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        defer { store.closeTransientSession() }
        await store.open(root)
        store.selectedCommit = store.commits.last?.hash
        let navigation = store.historyNavigationGeneration
        _ = try await GitProcess.run(at: root, arguments: ["checkout", "unrelated"])
        await store.refresh()
        XCTAssertEqual(store.selectedCommit, unrelated)
        XCTAssertNotEqual(store.historyNavigationGeneration, navigation)
        XCTAssertEqual(store.commits.first?.hash, unrelated)
        XCTAssertNil(store.historyRef); XCTAssertNil(store.historyPath)
        let explicit = try await repo.log(ref: "main")
        XCTAssertFalse(explicit.contains { $0.hash == unrelated })
    }
    func testCheckedScopeUnionAndEmptyIgnoreHighlightedRefAndStaleSelection() async throws {
        let (root, repo, side, unrelated) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        await store.open(root)
        store.checkedHistoryRefs = ["refs/heads/main", "refs/heads/side"]
        store.historyRef = "refs/heads/unrelated"; store.selectedCommit = unrelated
        await store.loadHistory(reset: true)
        let expected = try await repo.log(refs: ["refs/heads/main", "refs/heads/side"])
        XCTAssertEqual(store.commits, expected)
        XCTAssertTrue(store.commits.contains { $0.hash == side })
        XCTAssertFalse(store.commits.contains { $0.hash == unrelated })
        XCTAssertNil(store.selectedCommit)
        store.checkedHistoryRefs = []; store.selectedCommit = unrelated
        await store.loadHistory(reset: true)
        XCTAssertTrue(store.commits.isEmpty); XCTAssertNil(store.selectedCommit)
    }
    func testPinnedExplicitCommitRemainsVisibleOutsideCheckedBranches() async throws {
        let (root, _, _, unrelated) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        await store.open(root)
        store.checkedHistoryRefs = ["refs/heads/main"]
        store.historyRef = unrelated; store.historyPinnedCommit = unrelated; store.selectedCommit = unrelated
        await store.loadHistory(reset: true)
        XCTAssertEqual(store.commits.first?.hash, unrelated); XCTAssertEqual(store.selectedCommit, unrelated)
    }
    func testUnbornHEADHistoryIsEmpty() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitProcess.run(at: root, arguments: ["init"])
        let commits = try await GitRepository(url: root).log(ref: "HEAD", firstParent: true)
        XCTAssertTrue(commits.isEmpty)
    }
}
