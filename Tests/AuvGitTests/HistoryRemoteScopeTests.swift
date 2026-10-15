import XCTest
@testable import GitCore
@testable import AuvGit

@MainActor
final class HistoryRemoteScopeTests: XCTestCase {
    func testScopeUsesActualUpstreamsAndExplicitChecksWithoutGuessingNames() {
        let branches = [
            GitBranch(name: "main", isCurrent: true, isRemote: false, upstream: "refs/remotes/upstream/review"),
            GitBranch(name: "feature", isCurrent: false, isRemote: false, upstream: "origin/feature"),
            GitBranch(name: "untracked", isCurrent: false, isRemote: false),
            GitBranch(name: "upstream/review", isCurrent: false, isRemote: true),
            GitBranch(name: "origin/main", isCurrent: false, isRemote: true),
            GitBranch(name: "origin/feature", isCurrent: false, isRemote: true),
            GitBranch(name: "origin/untracked", isCurrent: false, isRemote: true),
            GitBranch(name: "origin/other", isCurrent: false, isRemote: true)
        ]
        XCTAssertEqual(HistoryBranchScope.remoteBranchNames(in: [], branches: branches), ["upstream/review"])
        XCTAssertEqual(HistoryBranchScope.remoteBranchNames(in: ["refs/heads/feature", "refs/heads/untracked", "refs/remotes/origin/other", "refs/remotes/origin/deleted"], branches: branches), ["upstream/review", "origin/feature", "origin/other"])
    }

    func testGraphHidesUncheckedRemoteLabelsAndDoesNotMarkTheirSharedLocalCommitRemoteOnly() {
        let commits = [GitCommit(hash: "head", parents: ["base"], author: "Test", date: .distantPast, subject: "head", body: "", refs: ["HEAD -> main"]),
            GitCommit(hash: "base", parents: [], author: "Test", date: .distantPast, subject: "base", body: "", refs: ["origin/other", "origin/main", "tag: v1", "local"])]
        let plan = HistoryGraphStylePlan(commits: commits, remoteBranchNames: ["origin/main", "origin/other"], visibleRemoteBranchNames: ["origin/main"])
        XCTAssertTrue(plan.isVisibleReference("origin/main"))
        XCTAssertFalse(plan.isVisibleReference("origin/other"))
        XCTAssertFalse(plan.isVisibleReference("refs/remotes/origin/other"))
        XCTAssertTrue(plan.isVisibleReference("HEAD -> main"))
        XCTAssertTrue(plan.isVisibleReference("tag: v1"))
        XCTAssertTrue(plan.isVisibleReference("local"))
        XCTAssertEqual(plan.nodeStyle(for: "base").kind, .ordinary)
        XCTAssertEqual(commits[1].refs.count, 4)
    }

    func testIncomingQueriesAndMainAndLogScopesExcludeUncheckedRemoteOnlyCommits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("auvgit-remote-scope-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = GitRepository(url: root)
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "fixture@example.invalid"], ["config", "commit.gpgsign", "false"], ["config", "core.hooksPath", root.appendingPathComponent("no-hooks").path], ["commit", "--allow-empty", "-m", "base"], ["branch", "feature"], ["remote", "add", "origin", root.path]] {
            _ = try await GitProcess.run(at: root, arguments: args)
        }
        let base = try await repository.workflowRevision("HEAD")
        let tree = try await repository.workflowRead(["rev-parse", "HEAD^{tree}"]).trimmingCharacters(in: .newlines)
        for name in ["main", "feature", "other"] {
            let tip = try await repository.workflowRead(["commit-tree", tree, "-p", base, "-m", "incoming-" + name]).trimmingCharacters(in: .newlines)
            _ = try await repository.workflowRead(["update-ref", "refs/remotes/origin/" + name, tip])
        }
        try await repository.setUpstream(branch: "main", remoteBranch: "refs/remotes/origin/main")
        try await repository.setUpstream(branch: "feature", remoteBranch: "refs/remotes/origin/feature")
        let all = try await repository.log(incomingOnly: true)
        XCTAssertEqual(Set(all.map(\.subject)), ["incoming-main", "incoming-feature", "incoming-other"])
        let scoped = try await repository.log(refs: ["refs/remotes/origin/main"], incomingOnly: true)
        XCTAssertEqual(scoped.map(\.subject), ["incoming-main"])
        let empty = try await repository.log(refs: [], incomingOnly: true)
        XCTAssertTrue(empty.isEmpty)

        let main = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        let log = RepositoryStore(persistsSession: false)
        defer { main.closeTransientSession(); log.closeTransientSession() }
        let branches = try await repository.branches()
        for store in [main, log] { store.repository = repository; store.repositoryURL = root; store.branches = branches }
        await main.loadHistory(reset: true)
        XCTAssertEqual(Set(main.commits.map(\.subject)), ["base", "incoming-main"])
        log.checkedHistoryRefs = ["refs/heads/feature"]
        await log.loadHistory(reset: true)
        XCTAssertEqual(Set(log.commits.map(\.subject)), ["base", "incoming-main", "incoming-feature"])
        XCTAssertFalse(log.hasMore)
        log.checkedHistoryRefs = ["refs/heads/feature", "refs/remotes/origin/other"]
        await log.loadHistory(reset: true)
        XCTAssertEqual(Set(log.commits.map(\.subject)), ["base", "incoming-main", "incoming-feature", "incoming-other"])
        log.checkedHistoryRefs = ["HEAD"]
        await log.loadHistory(reset: true)
        XCTAssertEqual(Set(log.commits.map(\.subject)), ["base", "incoming-main"])
    }
}
