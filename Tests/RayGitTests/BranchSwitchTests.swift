import XCTest
@testable import RayGit
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
        let repo = try await fixture()
        let linked = repo.url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: repo.url); try? FileManager.default.removeItem(at: linked) }
        _ = try await GitProcess.run(at: repo.url, arguments: ["worktree", "add", linked.path, "other"])
        let store = RepositoryStore(persistsSession: false)
        store.openRepositories = []
        store.recentPaths = []
        defer { store.closeTransientSession() }
        await store.open(repo.url)

        store.switchBranch(to: "other")
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
