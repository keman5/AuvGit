import XCTest
@testable import AuvGit
@testable import GitCore

@MainActor
final class BranchSwitchTests: XCTestCase {
    private func fixture() async throws -> GitRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await GitProcess.run(at: root, arguments: ["init", "-b", "main"])
        _ = try await GitProcess.run(at: root, arguments: ["config", "user.name", "Test"])
        _ = try await GitProcess.run(at: root, arguments: ["config", "user.email", "test@example.com"])
        try "base\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try await GitProcess.run(at: root, arguments: ["add", "file.txt"])
        _ = try await GitProcess.run(at: root, arguments: ["commit", "-m", "Fixture"])
        _ = try await GitProcess.run(at: root, arguments: ["branch", "other"])
        return GitRepository(url: root)
    }
    private func addLocalRemote(_ repo: GitRepository) async throws {
        _ = try await repo.workflowRead(["remote", "add", "origin", repo.url.path])
        _ = try await repo.workflowRead(["fetch", "origin"])
    }
    private func switchRemote(_ branch: String, repository: GitRepository) async throws -> String? {
        let destination = try await BranchSwitch.remoteDestination(repository: repository, branch: branch)
        return try await BranchSwitch.perform(repository: repository, branch: destination.branch,
            trackingRemote: destination.trackingRemote, isCurrentRepository: { true })
    }
    func testRemoteCreatesNestedLocalBranchWithUpstreamAndCarriesChanges() async throws {
        let repo = try await fixture(); defer { try? FileManager.default.removeItem(at: repo.url) }
        _ = try await repo.workflowRead(["branch", "feature/team/topic"])
        try await addLocalRemote(repo)
        _ = try await repo.workflowRead(["branch", "-D", "feature/team/topic"])
        try "dirty".write(to: repo.url.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let stash = try await switchRemote("origin/feature/team/topic", repository: repo)
        let current = try await repo.currentBranch()
        let upstream = try await repo.workflowRead(["rev-parse", "--symbolic-full-name", "@{upstream}"]).trimmingCharacters(in: .newlines)
        XCTAssertEqual(current, "feature/team/topic")
        XCTAssertEqual(upstream, "refs/remotes/origin/feature/team/topic")
        XCTAssertNil(stash)
        XCTAssertEqual(try String(contentsOf: repo.url.appendingPathComponent("file.txt"), encoding: .utf8), "dirty")
    }
    func testRemoteReusesExistingLocalWithoutResettingItsCommitOrTracking() async throws {
        let repo = try await fixture(); defer { try? FileManager.default.removeItem(at: repo.url) }
        try await addLocalRemote(repo)
        try await repo.checkout(branch: "other")
        try await repo.setUpstream(branch: "other", remoteBranch: "refs/remotes/origin/main")
        try "local only".write(to: repo.url.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file.txt"]); try await repo.commit(message: "Local only")
        let localHead = try await repo.workflowRevision("HEAD")
        try await repo.checkout(branch: "main")
        _ = try await switchRemote("origin/other", repository: repo)
        let current = try await repo.currentBranch(), actualHead = try await repo.workflowRevision("HEAD")
        let upstream = try await repo.workflowRead(["rev-parse", "--symbolic-full-name", "@{upstream}"]).trimmingCharacters(in: .newlines)
        XCTAssertEqual(current, "other"); XCTAssertEqual(actualHead, localHead)
        XCTAssertEqual(upstream, "refs/remotes/origin/main")
        _ = try await switchRemote("origin/other", repository: repo)
        let stashes = try await repo.stashes(); XCTAssertTrue(stashes.isEmpty)
    }
    func testRemoteReusesDifferentlyNamedTrackingBranch() async throws {
        let repo = try await fixture(); defer { try? FileManager.default.removeItem(at: repo.url) }
        try await addLocalRemote(repo)
        _ = try await repo.workflowRead(["branch", "-m", "other", "local-topic"])
        try await repo.setUpstream(branch: "local-topic", remoteBranch: "refs/remotes/origin/other")
        _ = try await switchRemote("origin/other", repository: repo)
        let current = try await repo.currentBranch()
        let branches = try await repo.branches()
        XCTAssertEqual(current, "local-topic")
        XCTAssertFalse(branches.contains { !$0.isRemote && $0.name == "other" })
    }
    func testNewRemoteBranchOverwriteRetainsStagedUnstagedAndUntrackedRecovery() async throws {
        let repo = try await fixture(); defer { try? FileManager.default.removeItem(at: repo.url) }
        let file = repo.url.appendingPathComponent("file.txt")
        try await repo.checkout(branch: "other")
        try "remote version".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file.txt"]); try await repo.commit(message: "Remote version")
        try await repo.checkout(branch: "main")
        try await addLocalRemote(repo)
        _ = try await repo.workflowRead(["branch", "-D", "other"])
        try "staged".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file.txt"])
        try "unstaged".write(to: file, atomically: true, encoding: .utf8)
        try "untracked".write(to: repo.url.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let saved = try await switchRemote("origin/other", repository: repo)
        let stash = try XCTUnwrap(saved)
        let current = try await repo.currentBranch()
        let staged = try await repo.workflowRead(["show", stash + "^2:file.txt"])
        let unstaged = try await repo.workflowRead(["show", stash + ":file.txt"])
        let untracked = try await repo.workflowRead(["show", stash + "^3:new.txt"])
        XCTAssertEqual(current, "other")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "remote version")
        XCTAssertEqual(staged, "staged"); XCTAssertEqual(unstaged, "unstaged"); XCTAssertEqual(untracked, "untracked")
    }
    func testUnresolvedConflictDoesNotCreateRemoteLocalBranchOrStash() async throws {
        let repo = try await fixture(); defer { try? FileManager.default.removeItem(at: repo.url) }
        let file = repo.url.appendingPathComponent("file.txt")
        try await repo.checkout(branch: "other")
        try "theirs\n".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file.txt"]); try await repo.commit(message: "Theirs")
        try await repo.checkout(branch: "main")
        try await addLocalRemote(repo)
        try "ours\n".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file.txt"]); try await repo.commit(message: "Ours")
        _ = try await GitProcess.run(at: repo.url, arguments: ["merge", "other"], allowedCodes: [0, 1])
        _ = try await repo.workflowRead(["branch", "-D", "other"])
        let conflicted = try String(contentsOf: file, encoding: .utf8)
        do { _ = try await switchRemote("origin/other", repository: repo); XCTFail("Unresolved conflicts must block switching") }
        catch is GitError {}
        let current = try await repo.currentBranch(), branches = try await repo.branches(), stashes = try await repo.stashes()
        let status = try await repo.status()
        XCTAssertEqual(current, "main"); XCTAssertTrue(status.contains(where: \.isConflict))
        XCTAssertFalse(branches.contains { !$0.isRemote && $0.name == "other" }); XCTAssertTrue(stashes.isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), conflicted)
    }
    func testTransferableChangesSwitchWithoutStash() async throws {
        let repo = try await fixture(); defer { try? FileManager.default.removeItem(at: repo.url) }
        try "dirty".write(to: repo.url.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let stash = try await BranchSwitch.perform(repository: repo, branch: "other", isCurrentRepository: { true })
        XCTAssertNil(stash)
        let branch = try await repo.currentBranch(); XCTAssertEqual(branch, "other")
        XCTAssertEqual(try String(contentsOf: repo.url.appendingPathComponent("file.txt"), encoding: .utf8), "dirty")
    }
    func testOverwriteStashesIndexWorktreeAndUntrackedAndRetainsRecovery() async throws {
        let repo = try await fixture(); defer { try? FileManager.default.removeItem(at: repo.url) }
        try await repo.checkout(branch: "other")
        let file = repo.url.appendingPathComponent("file.txt")
        try "other".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file.txt"]); try await repo.commit(message: "Other")
        try await repo.checkout(branch: "main")
        try "staged".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file.txt"])
        try "unstaged".write(to: file, atomically: true, encoding: .utf8)
        try "untracked".write(to: repo.url.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let saved = try await BranchSwitch.perform(repository: repo, branch: "other", isCurrentRepository: { true })
        let stash = try XCTUnwrap(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("new.txt").path))
        let branch = try await repo.currentBranch(); XCTAssertEqual(branch, "other")
        let stashHead = try await repo.workflowRevision("refs/stash"); XCTAssertEqual(stashHead, stash)
        try await repo.checkout(branch: "main")
        _ = try await GitProcess.run(at: repo.url, arguments: ["stash", "apply", "--index", stash])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "unstaged")
        let index = try await repo.workflowRead(["show", ":file.txt"]); XCTAssertEqual(index, "staged")
        XCTAssertEqual(try String(contentsOf: repo.url.appendingPathComponent("new.txt"), encoding: .utf8), "untracked")
    }
    func testUnrelatedFailureDoesNotStash() async throws {
        let repo = try await fixture(); defer { try? FileManager.default.removeItem(at: repo.url) }
        try "dirty".write(to: repo.url.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        do { _ = try await BranchSwitch.perform(repository: repo, branch: "missing", isCurrentRepository: { true }); XCTFail("Expected missing branch error") } catch is GitError {}
        let stashes = try await repo.stashes(); XCTAssertTrue(stashes.isEmpty)
        XCTAssertEqual(try String(contentsOf: repo.url.appendingPathComponent("file.txt"), encoding: .utf8), "dirty")
    }
    func testUntrackedOverwriteCollisionIsSavedBeforeSwitch() async throws {
        let repo = try await fixture(); defer { try? FileManager.default.removeItem(at: repo.url) }
        try await repo.checkout(branch: "other")
        let file = repo.url.appendingPathComponent("collision.txt")
        try "branch content".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["collision.txt"]); try await repo.commit(message: "Tracked destination")
        try await repo.checkout(branch: "main")
        try "untracked work".write(to: file, atomically: true, encoding: .utf8)
        let saved = try await BranchSwitch.perform(repository: repo, branch: "other", isCurrentRepository: { true })
        let stash = try XCTUnwrap(saved)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "branch content")
        let recovered = try await repo.workflowRead(["show", stash + "^3:collision.txt"])
        XCTAssertEqual(recovered, "untracked work")
    }
    func testSelectingBranchOwnedByLinkedWorktreeOpensThatProject() async throws {
        try await checkBranchOwnedByLinkedWorktree(isRemote: false)
    }
    func testRemoteBranchOwnedByLinkedWorktreeOpensThatProject() async throws {
        try await checkBranchOwnedByLinkedWorktree(isRemote: true)
    }
    private func checkBranchOwnedByLinkedWorktree(isRemote: Bool) async throws {
        let repo = try await fixture()
        let linked = repo.url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: repo.url); try? FileManager.default.removeItem(at: linked) }
        _ = try await GitProcess.run(at: repo.url, arguments: ["worktree", "add", linked.path, "other"])
        let store = RepositoryStore(persistsSession: false)
        store.openRepositories = []
        store.recentPaths = []
        defer { store.closeTransientSession() }
        await store.open(repo.url)

        if isRemote { try await addLocalRemote(repo) }
        store.switchBranch(to: isRemote ? "origin/other" : "other", isRemote: isRemote)
        for _ in 0..<500 {
            if store.repositoryURL.map({ RepositoryStore.sameRepositoryLocation($0, linked) }) == true, !store.isBusy { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let mainBranch = try await GitRepository(url: repo.url).currentBranch()
        let linkedBranch = try await GitRepository(url: linked).currentBranch()
        let stashes = try await GitRepository(url: repo.url).stashes()
        XCTAssertTrue(try XCTUnwrap(store.repositoryURL).path.hasSuffix(linked.lastPathComponent))
        XCTAssertEqual(mainBranch, "main")
        XCTAssertEqual(linkedBranch, "other")
        XCTAssertTrue(stashes.isEmpty)
        XCTAssertNil(store.error)
    }
    func testSelectedBranchUpstreamAndRemoteStopTrackingAreExactlyScoped() async throws {
        let repo = try await fixture(); defer { try? FileManager.default.removeItem(at: repo.url) }
        _ = try await GitProcess.run(at: repo.url, arguments: ["remote", "add", "origin", repo.url.path])
        _ = try await GitProcess.run(at: repo.url, arguments: ["fetch", "origin"])
        try await repo.setUpstream(branch: "other", remoteBranch: "refs/remotes/origin/main")
        try await repo.setUpstream(branch: "main", remoteBranch: "refs/remotes/origin/other")
        let selected = try await repo.workflowRead(["for-each-ref", "--format=%(upstream)", "refs/heads/other"])
        XCTAssertEqual(selected.trimmingCharacters(in: .newlines), "refs/remotes/origin/main")
        try await repo.stopTracking(remoteBranch: "refs/remotes/origin/main")
        let removed = try await repo.workflowRead(["for-each-ref", "--format=%(upstream)", "refs/heads/other"])
        let preserved = try await repo.workflowRead(["for-each-ref", "--format=%(upstream)", "refs/heads/main"])
        XCTAssertTrue(removed.trimmingCharacters(in: .newlines).isEmpty)
        XCTAssertEqual(preserved.trimmingCharacters(in: .newlines), "refs/remotes/origin/other")
        let remote = try await repo.workflowRevision("refs/remotes/origin/main")
        let head = try await repo.workflowRevision("HEAD")
        XCTAssertEqual(remote, head)
        let branch = try await repo.currentBranch(); XCTAssertEqual(branch, "main")
    }
}
