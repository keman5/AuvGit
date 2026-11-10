import XCTest
@testable import GitCore

final class GitInteractionTests: XCTestCase {
    private func fixture() async throws -> (URL, GitRepository) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"]] {
            _ = try await GitProcess.run(at: url, arguments: args)
        }
        return (url, GitRepository(url: url))
    }
    private func write(_ text: String, _ path: String, at url: URL) throws {
        try text.write(to: url.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    private func rejected(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected rejection") } catch { }
    }
    func testDiscardPreservesIndexAndPreflightsEveryPath() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("base", "tracked", at: url)
        try await repo.stage(paths: ["tracked"]); try await repo.commit(message: "base")
        try write("staged", "tracked", at: url); try await repo.stage(paths: ["tracked"])
        try write("working", "tracked", at: url); try write("new", "untracked", at: url)
        await rejected { try await repo.discardWorktree(paths: ["tracked", "untracked"]) }
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("tracked"), encoding: .utf8), "working")
        await rejected { try await repo.discardWorktree(paths: ["../outside"]) }
        await rejected { try await repo.discardWorktree(paths: ["missing"]) }
        try await repo.discardWorktree(paths: ["tracked"])
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("tracked"), encoding: .utf8), "staged")
        let status = try await repo.status()
        XCTAssertTrue(status.contains { $0.path == "tracked" && $0.isStaged && !$0.isUnstaged })
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("untracked").path))
    }
    func testFileHistoryFollowsRenameFiltersBeforePaginationAndValidatesRef() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("base", "old", at: url); try await repo.stage(paths: ["old"]); try await repo.commit(message: "match root")
        try write("other", "other", at: url); try await repo.stage(paths: ["other"]); try await repo.commit(message: "match unrelated")
        try FileManager.default.moveItem(at: url.appendingPathComponent("old"), to: url.appendingPathComponent("new"))
        try await repo.stage(paths: ["old", "new"]); try await repo.commit(message: "match rename")
        let history = try await repo.log(path: "new")
        XCTAssertEqual(history.map(\.subject), ["match rename", "match root"])
        let page = try await repo.log(limit: 1, skip: 1, search: "match", path: "new", ref: "main")
        XCTAssertEqual(page.map(\.subject), ["match root"])
        await rejected { _ = try await repo.log(ref: "--all") }
    }
    func testBranchTagDetachedCherryPickRevertAndDirtyRejection() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("base", "base", at: url); try await repo.stage(paths: ["base"]); try await repo.commit(message: "base")
        let base = try await repo.log()[0].hash
        try await repo.createBranch(name: "topic", startPoint: base)
        let current = try await repo.currentBranch(); XCTAssertEqual(current, "main")
        try await repo.renameBranch(oldName: "topic", newName: "renamed")
        try await repo.createTag(name: "v1", commit: base)
        await rejected { try await repo.createTag(name: "--bad", commit: base) }
        try await repo.checkout(branch: "renamed")
        try write("feature", "feature", at: url); try await repo.stage(paths: ["feature"]); try await repo.commit(message: "feature")
        let feature = try await repo.log(ref: "HEAD")[0].hash
        try await repo.checkout(branch: "main")
        await rejected { try await repo.deleteBranch(name: "renamed") }
        try write("dirty", "base", at: url)
        await rejected { try await repo.cherryPick(hash: feature) }
        await rejected { try await repo.revert(hash: base) }
        try await repo.discardWorktree(paths: ["base"])
        try await repo.cherryPick(hash: feature)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("feature").path))
        let picked = try await repo.log(ref: "HEAD")[0].hash
        try await repo.revert(hash: picked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("feature").path))
        try await repo.createBranch(name: "merged", startPoint: "HEAD")
        try await repo.deleteBranch(name: "merged")
        try await repo.checkoutCommit(hash: "v1")
        let detached = try await repo.currentBranch(); XCTAssertTrue(detached.hasPrefix("Detached "))
    }
    func testStashDiffAndDrop() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("base", "file", at: url); try await repo.stage(paths: ["file"]); try await repo.commit(message: "base")
        try write("changed", "file", at: url); try await repo.stash(message: "changes")
        let ref = try await repo.stashes()[0].ref
        let diff = try await repo.stashDiff(ref: ref); XCTAssertTrue(diff.contains("+changed"))
        await rejected { try await repo.dropStash(ref: "--all") }
        try await repo.dropStash(ref: ref)
        let stashes = try await repo.stashes(); XCTAssertTrue(stashes.isEmpty)
    }
    func testBatchStashDropKeepsUnselectedEntriesAndRejectsRenumberedTargets() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("base", "file", at: url); try await repo.stage(paths: ["file"]); try await repo.commit(message: "base")
        for index in 0..<4 {
            try write("change \(index)", "file", at: url)
            try await repo.stash(message: "stash \(index)")
        }
        let original = try await repo.stashes()
        try await repo.dropStashes([original[0], original[2]])
        let remaining = try await repo.stashes()
        XCTAssertEqual(remaining.map(\.hash), [original[1].hash, original[3].hash])
        await rejected { try await repo.dropStashes([remaining[0], original[2]]) }
        let unchanged = try await repo.stashes()
        XCTAssertEqual(unchanged.map(\.hash), remaining.map(\.hash), "Validate the whole batch before dropping any stash")
        try write("new change", "file", at: url); try await repo.stash(message: "new stash")
        await rejected { try await repo.dropStashes(remaining) }
        let after = try await repo.stashes()
        XCTAssertEqual(after.count, 3)
    }
    func testForceDeleteRequiresFreshBranchTipAndRejectsCurrentBranch() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("base", "base", at: url); try await repo.stage(paths: ["base"]); try await repo.commit(message: "base")
        try await repo.createBranch(name: "website/app-store")
        try write("topic", "topic", at: url); try await repo.stage(paths: ["topic"]); try await repo.commit(message: "topic")
        let hash = try await repo.workflowRevision("HEAD")
        await rejected { try await repo.deleteBranch(name: "website/app-store", force: true) }
        try await repo.checkout(branch: "main")
        do { try await repo.deleteBranch(name: "website/app-store"); XCTFail("Unmerged deletion accepted") }
        catch let error as BranchDeletionNeedsForce { XCTAssertEqual(error.name, "website/app-store"); XCTAssertEqual(error.hash, hash) }
        await rejected { try await repo.deleteBranch(name: "website/app-store", force: true, expectedHash: "stale") }
        try await repo.deleteBranch(name: "website/app-store", force: true, expectedHash: hash)
        let branches = try await repo.branches()
        XCTAssertFalse(branches.contains { $0.name == "website/app-store" })
    }
    func testRemoteCreationTracksWithAutoSetupDisabledAndDeletionTargetsSelectedRemote() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let bare = url.appendingPathComponent("remote.git")
        _ = try await GitProcess.run(at: url, arguments: ["init", "--bare", bare.path])
        try write("base", "base", at: url); try await repo.stage(paths: ["base"]); try await repo.commit(message: "base")
        _ = try await repo.workflowRead(["remote", "add", "team", bare.path])
        _ = try await repo.workflowRead(["push", "team", "HEAD:refs/heads/website/app-store"])
        _ = try await repo.workflowRead(["fetch", "team"])
        _ = try await repo.workflowRead(["config", "branch.autoSetupMerge", "false"])
        try await repo.createBranch(name: "local-site", startPoint: "refs/remotes/team/website/app-store")
        var branches = try await repo.branches()
        XCTAssertEqual(branches.first { $0.name == "local-site" }?.upstream, "team/website/app-store")
        let current = try await repo.currentBranch(); XCTAssertEqual(current, "main")
        try await repo.setUpstream(branch: "local-site", remoteBranch: nil)
        branches = try await repo.branches(); XCTAssertNil(branches.first { $0.name == "local-site" }?.upstream)
        try await repo.deleteRemoteBranch(reference: "refs/remotes/team/website/app-store")
        let advertised = try await repo.workflowRead(["ls-remote", "--heads", "team"])
        XCTAssertTrue(advertised.isEmpty)
        branches = try await repo.branches()
        XCTAssertTrue(branches.contains { $0.name == "local-site" })
        XCTAssertFalse(branches.contains { $0.name == "team/website/app-store" })
    }
    func testRemoteDeletionRefusesNewServerCommitsAndUsesCustomFetchMapping() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let bare = url.appendingPathComponent("remote.git")
        _ = try await GitProcess.run(at: url, arguments: ["init", "--bare", bare.path])
        try write("base", "base", at: url); try await repo.stage(paths: ["base"]); try await repo.commit(message: "base")
        _ = try await repo.workflowRead(["remote", "add", "team", bare.path])
        _ = try await repo.workflowRead(["config", "remote.team.fetch", "+refs/heads/*:refs/remotes/custom/*"])
        _ = try await repo.workflowRead(["push", "team", "HEAD:refs/heads/topic"])
        _ = try await repo.workflowRead(["fetch", "team"])
        let target = try await repo.remoteBranchDestination("refs/remotes/custom/topic")
        XCTAssertEqual(target.remote, "team"); XCTAssertEqual(target.branch, "refs/heads/topic")
        let original = try await repo.workflowRevision("HEAD")
        try write("new", "base", at: url); try await repo.stage(paths: ["base"]); try await repo.commit(message: "new")
        let newHash = try await repo.workflowRevision("HEAD")
        _ = try await GitProcess.run(at: bare, arguments: ["fetch", url.path, "main:refs/heads/topic"])
        let tracking = try await repo.workflowRevision("refs/remotes/custom/topic")
        XCTAssertEqual(tracking, original)
        do {
            try await repo.deleteRemoteBranch(reference: "refs/remotes/custom/topic")
            XCTFail("Deletion must refuse unseen server commits")
        } catch {
            XCTAssertEqual(GitFailureSummary.key(for: error.localizedDescription), "Remote branch changed; fetch updates and confirm deletion again")
        }
        let head = try await GitProcess.run(at: bare, arguments: ["rev-parse", "refs/heads/topic"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(head, newHash)
    }
    func testRemoteDeletionCleansAlreadyDeletedTrackingRefAndPreservesLocalBranch() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let bare = url.appendingPathComponent("remote.git")
        _ = try await GitProcess.run(at: url, arguments: ["init", "--bare", bare.path])
        try write("base", "base", at: url); try await repo.stage(paths: ["base"]); try await repo.commit(message: "base")
        _ = try await repo.workflowRead(["remote", "add", "team", bare.path])
        _ = try await repo.workflowRead(["config", "remote.team.fetch", "+refs/heads/*:refs/remotes/custom/*"])
        _ = try await repo.workflowRead(["push", "team", "HEAD:refs/heads/topic"])
        _ = try await repo.workflowRead(["fetch", "team"])
        let original = try await repo.workflowRevision("HEAD")
        _ = try await GitProcess.run(at: bare, arguments: ["update-ref", "-d", "refs/heads/topic"])
        try await repo.deleteRemoteBranch(reference: "refs/remotes/custom/topic")
        let refs = try await repo.workflowRead(["for-each-ref", "--format=%(refname)", "refs/remotes/custom/topic"])
        XCTAssertTrue(refs.isEmpty)
        let local = try await repo.workflowRevision("refs/heads/main")
        XCTAssertEqual(local, original)
    }
    func testRemoteDeletionChecksPushEndpointInsteadOfFetchEndpoint() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let fetchURL = url.appendingPathComponent("fetch.git"), pushURL = url.appendingPathComponent("push.git")
        for remote in [fetchURL, pushURL] { _ = try await GitProcess.run(at: url, arguments: ["init", "--bare", remote.path]) }
        try write("base", "base", at: url); try await repo.stage(paths: ["base"]); try await repo.commit(message: "base")
        _ = try await repo.workflowRead(["remote", "add", "team", fetchURL.path])
        _ = try await repo.workflowRead(["push", "team", "HEAD:refs/heads/topic"])
        _ = try await repo.workflowRead(["fetch", "team"])
        _ = try await repo.workflowRead(["push", pushURL.path, "HEAD:refs/heads/topic"])
        _ = try await repo.workflowRead(["config", "remote.team.pushurl", pushURL.path])
        _ = try await GitProcess.run(at: fetchURL, arguments: ["update-ref", "-d", "refs/heads/topic"])
        try await repo.deleteRemoteBranch(reference: "refs/remotes/team/topic")
        let heads = try await GitProcess.run(at: pushURL, arguments: ["for-each-ref", "--format=%(refname)", "refs/heads/topic"]).text
        XCTAssertTrue(heads.isEmpty)
    }
    func testRemoteDeletionLeaseRejectsCommitArrivingAfterPreflight() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let bare = url.appendingPathComponent("remote.git")
        _ = try await GitProcess.run(at: url, arguments: ["init", "--bare", bare.path])
        try write("base", "base", at: url); try await repo.stage(paths: ["base"]); try await repo.commit(message: "base")
        _ = try await repo.workflowRead(["remote", "add", "team", bare.path])
        _ = try await repo.workflowRead(["push", "team", "HEAD:refs/heads/topic"])
        _ = try await repo.workflowRead(["fetch", "team"])
        let original = try await repo.workflowRevision("HEAD")
        try write("next", "base", at: url); try await repo.stage(paths: ["base"]); try await repo.commit(message: "next")
        let next = try await repo.workflowRevision("HEAD")
        _ = try await GitProcess.run(at: bare, arguments: ["fetch", url.path, "main"])
        try write(next, ".git/advance-to", at: url)
        let wrapper = url.appendingPathComponent("git-wrapper")
        try """
        #!/bin/sh
        for arg in "$@"; do
          if [ "$arg" = push ]; then
            /usr/bin/git --git-dir=remote.git update-ref refs/heads/topic "$(cat .git/advance-to)" || exit 1
            break
          fi
        done
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let defaults = UserDefaults.standard, key = "auvgit.git.executablePath", previous = defaults.object(forKey: key)
        defaults.set(wrapper.path, forKey: key)
        defer { if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) } }
        do {
            try await repo.deleteRemoteBranch(reference: "refs/remotes/team/topic")
            XCTFail("Deletion must retain the lease after preflight")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("stale info"))
            XCTAssertEqual(GitFailureSummary.key(for: error.localizedDescription), "Remote branch changed; fetch updates and confirm deletion again")
        }
        let server = try await GitProcess.run(at: bare, arguments: ["rev-parse", "refs/heads/topic"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(server, next)
        let tracking = try await repo.workflowRevision("refs/remotes/team/topic")
        XCTAssertEqual(tracking, original)
    }
}
