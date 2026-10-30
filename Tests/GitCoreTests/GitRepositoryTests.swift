import XCTest
@testable import GitCore

final class GitRepositoryTests: XCTestCase {
    func testStageDirectoryReplacedBySymlinkOrFileWithoutFollowingTarget() async throws {
        for replacement in ["symlink", "broken-symlink", "file"] {
            for stageReplacement in [false, true] {
                let (url, repo) = try await fixture()
                defer { try? FileManager.default.removeItem(at: url) }
                let folder = url.appendingPathComponent("profiles")
                let destination = url.appendingPathComponent("new-profiles")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try "old".write(to: folder.appendingPathComponent("theme.json"), atomically: true, encoding: .utf8)
                try "sibling".write(to: folder.appendingPathComponent("other.json"), atomically: true, encoding: .utf8)
                try "target".write(to: destination.appendingPathComponent("theme.json"), atomically: true, encoding: .utf8)
                try await repo.stage(paths: ["profiles"]); try await repo.commit(message: "Base")
                try FileManager.default.removeItem(at: folder)
                if replacement == "file" {
                    try "replacement".write(to: folder, atomically: true, encoding: .utf8)
                } else {
                    try FileManager.default.createSymbolicLink(atPath: folder.path,
                        withDestinationPath: replacement == "symlink" ? "new-profiles" : "missing-profiles")
                }
                let paths = stageReplacement ? ["profiles", "profiles/theme.json", "profiles/other.json"] : ["profiles/theme.json"]
                try await repo.stage(paths: paths)
                let staged = try await GitProcess.run(at: url, arguments: ["diff", "--cached", "--name-only", "-z"])
                let expected = stageReplacement ? ["profiles", "profiles/other.json", "profiles/theme.json"] : ["profiles/theme.json"]
                XCTAssertEqual(Set(staged.text.split(separator: "\0").map(String.init)), Set(expected))
                XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("theme.json"), encoding: .utf8), "target")
                if stageReplacement { try await repo.stage(paths: paths) }
            }
        }
    }

    func testCreateBranchAtCommitSwitchesWhenRequestedAndPreservesDraft() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        try "base".write(to: url.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file"]); try await repo.commit(message: "Base")
        try "draft".write(to: url.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try await repo.createBranch(name: "feature/new", startPoint: "HEAD", switchAfterCreation: true)
        let branch = try await repo.currentBranch()
        XCTAssertEqual(branch, "feature/new")
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("file"), encoding: .utf8), "draft")
    }

    func testFirstPushUsesChosenRemoteBranchAndSetsUpstreamOnlyOnSuccess() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let remote = url.appendingPathComponent("target.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        _ = try await GitProcess.run(at: remote, arguments: ["init", "--bare"])
        _ = try await GitProcess.run(at: url, arguments: ["remote", "add", "chosen", remote.path])
        try "base".write(to: url.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file"]); try await repo.commit(message: "Base")
        let pending = try await repo.firstPushRequest()
        let request = try XCTUnwrap(pending)
        XCTAssertEqual(request.branch, "main")
        XCTAssertEqual(request.remotes, ["chosen"])
        try await repo.pushFirstBranch(request, remote: "chosen", remoteBranch: "review/new")
        let branches = try await repo.branches()
        XCTAssertEqual(branches.first { $0.isCurrent }?.upstream, "chosen/review/new")
        let advertised = try await GitProcess.run(at: remote, arguments: ["rev-parse", "refs/heads/review/new"])
        XCTAssertEqual(advertised.text.trimmingCharacters(in: .newlines), request.commit)
        let next = try await repo.firstPushRequest()
        XCTAssertNil(next)
    }

    func testFirstPushRejectsChangedHeadWithoutCreatingRemoteBranch() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await GitProcess.run(at: url, arguments: ["remote", "add", "origin", "/unused-remote"])
        try "base".write(to: url.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file"]); try await repo.commit(message: "Base")
        let pending = try await repo.firstPushRequest()
        let request = try XCTUnwrap(pending)
        try await repo.createBranch(name: "different")
        do { try await repo.pushFirstBranch(request, remote: "origin", remoteBranch: "main"); XCTFail("Stale selection must not push") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        let branches = try await repo.branches()
        XCTAssertNil(branches.first { $0.isCurrent }?.upstream)
    }

    func testCreateBranchSwitchRefusalRetainsBranchAndUncommittedChanges() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("file")
        try "base".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file"]); try await repo.commit(message: "Base")
        let base = try await repo.workflowRevision("HEAD")
        try "new".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file"]); try await repo.commit(message: "New")
        try "draft".write(to: file, atomically: true, encoding: .utf8)
        do { try await repo.createBranch(name: "created", startPoint: base, switchAfterCreation: true); XCTFail("Switch must refuse overwrite") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Branch created: created")) }
        let current = try await repo.currentBranch()
        let created = try await repo.workflowRevision("refs/heads/created")
        XCTAssertEqual(current, "main")
        XCTAssertEqual(created, base)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "draft")
    }

    func testRejectedFirstPushLeavesUpstreamUnsetAndMissingUpstreamOffersSelection() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await GitProcess.run(at: url, arguments: ["remote", "add", "origin", url.appendingPathComponent("missing.git").path])
        try "base".write(to: url.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file"]); try await repo.commit(message: "Base")
        let pending = try await repo.firstPushRequest()
        let request = try XCTUnwrap(pending)
        do { try await repo.pushFirstBranch(request, remote: "origin", remoteBranch: "new"); XCTFail("Unavailable remote must fail") } catch { }
        let branches = try await repo.branches()
        XCTAssertNil(branches.first { $0.isCurrent }?.upstream)
        _ = try await GitProcess.run(at: url, arguments: ["config", "branch.main.remote", "origin"])
        _ = try await GitProcess.run(at: url, arguments: ["config", "branch.main.merge", "refs/heads/deleted"])
        let missing = try await repo.firstPushRequest()
        XCTAssertNotNil(missing)
    }
    func testBranchTrackingMetadataAndConfigOnlyRefresh() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await GitProcess.run(at: url, arguments: ["config", "commit.gpgsign", "false"])
        try "base\n".write(to: url.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["tracked.txt"]); try await repo.commit(message: "Initial")
        _ = try await GitProcess.run(at: url, arguments: ["remote", "add", "origin", "/unused-local-remote"])
        _ = try await GitProcess.run(at: url, arguments: ["update-ref", "refs/remotes/origin/main", "HEAD"])
        _ = try await GitProcess.run(at: url, arguments: ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        let before = try await repo.changeState(files: [])
        try await repo.setUpstream(branch: "main", remoteBranch: "refs/remotes/origin/main")
        let tracked = try await repo.branches()
        XCTAssertEqual(tracked.first { !$0.isRemote }?.upstream, "origin/main")
        XCTAssertTrue(tracked.filter(\.isRemote).allSatisfy { $0.upstream == nil })
        XCTAssertFalse(tracked.contains { $0.name == "origin/HEAD" })
        let after = try await repo.changeState(files: [])
        XCTAssertNotEqual(before.history, after.history)
        try await repo.setUpstream(branch: "main", remoteBranch: nil)
        let untracked = try await repo.branches()
        XCTAssertNil(untracked.first { !$0.isRemote }?.upstream)
        let cleared = try await repo.changeState(files: [])
        XCTAssertEqual(before.history, cleared.history)
        let old = Data(#"{"name":"main","isCurrent":true,"isRemote":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(GitBranch.self, from: old).upstream)
        XCTAssertEqual(try JSONDecoder().decode(GitBranch.self, from: JSONEncoder().encode(tracked[0])), tracked[0])
    }
    private func fixture() async throws -> (URL, GitRepository) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try await GitProcess.run(at: url, arguments: ["init", "-b", "main"])
        _ = try await GitProcess.run(at: url, arguments: ["config", "user.name", "Test"])
        _ = try await GitProcess.run(at: url, arguments: ["config", "user.email", "test@example.invalid"])
        return (url, try await GitRepository.open(url))
    }
    func testUnbornStageUnstageRootHistoryAndDiff() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let emptyLog = try await repo.log()
        XCTAssertTrue(emptyLog.isEmpty)
        let path = "[literal] file with spaces\nand newline.txt"
        try "first line\n".write(to: url.appendingPathComponent(path), atomically: true, encoding: .utf8)
        let initial = try await repo.status()
        XCTAssertEqual(initial.first?.path, path)
        XCTAssertTrue(initial.first?.isUntracked == true)
        let untracked = try await repo.diff(target: .worktree(path: path, untracked: true))
        XCTAssertTrue(untracked.contains("+first line"))
        try await repo.stage(paths: [path])
        try await repo.unstage(paths: [path])
        let unstaged = try await repo.status()
        XCTAssertTrue(unstaged.first?.isUntracked == true)
        try await repo.stage(paths: [path])
        try await repo.commit(message: "Root subject\n\nDetailed body")
        let commits = try await repo.log()
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.subject, "Root subject")
        XCTAssertTrue(commits.first?.body.contains("Detailed body") == true)
        XCTAssertTrue(commits.first?.parents.isEmpty == true)
        let files = try await repo.commitFiles(hash: commits[0].hash)
        XCTAssertEqual(files.first?.path, path)
        let diff = try await repo.diff(target: .commit(hash: commits[0].hash, path: path))
        XCTAssertTrue(diff.contains("+first line"))
        let matching = try await repo.log(search: "Detailed body")
        XCTAssertEqual(matching.count, 1)
        let skipped = try await repo.log(skip: 1)
        XCTAssertTrue(skipped.isEmpty)
        let clean = try await repo.status()
        XCTAssertTrue(clean.isEmpty)
    }
    func testRenameUnstageAndBranchesStash() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        try "hello\n".write(to: url.appendingPathComponent("old name.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["old name.txt"])
        try await repo.commit(message: "Initial")
        try FileManager.default.moveItem(at: url.appendingPathComponent("old name.txt"), to: url.appendingPathComponent("new name.txt"))
        try await repo.stage(paths: ["old name.txt", "new name.txt"])
        let renamed = try await repo.status()
        XCTAssertEqual(renamed.first?.originalPath, "old name.txt")
        try await repo.stage(paths: ["old name.txt", "new name.txt"]) // Re-staging a staged rename is harmless.
        try await repo.unstage(paths: ["new name.txt"])
        let unstaged = try await repo.status()
        XCTAssertFalse(unstaged.contains { $0.isStaged })
        try await repo.stage(paths: ["old name.txt", "new name.txt"])
        try await repo.commit(message: "Rename")
        let commits = try await repo.log()
        let files = try await repo.commitFiles(hash: commits[0].hash)
        XCTAssertEqual(files.first?.originalPath, "old name.txt")
        try await repo.createBranch(name: "feature")
        let branch = try await repo.currentBranch()
        XCTAssertEqual(branch, "feature")
        try await repo.checkout(branch: "main")
        try "changed\n".write(to: url.appendingPathComponent("new name.txt"), atomically: true, encoding: .utf8)
        try await repo.stash(message: "My stash")
        let stashes = try await repo.stashes()
        XCTAssertEqual(stashes.count, 1)
        try await repo.applyStash(ref: stashes[0].ref)
        let restored = try await repo.status()
        XCTAssertEqual(restored.first?.path, "new name.txt")
    }
    func testMergeFilesUseFirstParentAndDetachedHistory() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        try "base\n".write(to: url.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["base.txt"]); try await repo.commit(message: "Base")
        try await repo.createBranch(name: "feature")
        try "feature\n".write(to: url.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["feature.txt"]); try await repo.commit(message: "Feature")
        try await repo.checkout(branch: "main")
        try "main\n".write(to: url.appendingPathComponent("main.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["main.txt"]); try await repo.commit(message: "Main")
        _ = try await GitProcess.run(at: url, arguments: ["merge", "--no-ff", "feature", "-m", "Merge"])
        let history = try await repo.log()
        XCTAssertEqual(history[0].parents.count, 2)
        let files = try await repo.commitFiles(hash: history[0].hash)
        XCTAssertEqual(files.map(\.path), ["feature.txt"])
        let diff = try await repo.diff(target: .commit(hash: history[0].hash, path: "feature.txt"))
        XCTAssertTrue(diff.contains("+feature"))
        _ = try await GitProcess.run(at: url, arguments: ["switch", "--detach", "HEAD"])
        try "detached\n".write(to: url.appendingPathComponent("detached.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["detached.txt"]); try await repo.commit(message: "Detached only")
        let detachedHistory = try await repo.log()
        XCTAssertTrue(detachedHistory.contains { $0.subject == "Detached only" })
    }

    func testCreateLocalBranchAtRemotePreservesCheckoutAndDraft() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("sample.txt")
        try "remote\n".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["sample.txt"]); try await repo.commit(message: "Remote tip")
        let remote = try await GitProcess.run(at: url, arguments: ["rev-parse", "HEAD"])
        let remoteHash = remote.text.trimmingCharacters(in: .newlines)
        _ = try await GitProcess.run(at: url, arguments: ["remote", "add", "origin", "/unused-local-remote"])
        _ = try await GitProcess.run(at: url, arguments: ["update-ref", "refs/remotes/origin/feature/nested", remoteHash])
        try "local\n".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["sample.txt"]); try await repo.commit(message: "Different local tip")
        try "draft\n".write(to: file, atomically: true, encoding: .utf8)

        try await repo.createBranch(name: "feature/nested", startPoint: "refs/remotes/origin/feature/nested")
        let created = try await GitProcess.run(at: url, arguments: ["rev-parse", "refs/heads/feature/nested"])
        XCTAssertEqual(created.text.trimmingCharacters(in: .newlines), remoteHash)
        let current = try await repo.currentBranch()
        XCTAssertEqual(current, "main")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "draft\n")
        do { try await repo.createBranch(name: "feature/nested", startPoint: "refs/remotes/origin/feature/nested"); XCTFail("Existing branch must not be overwritten") } catch { }
        do { try await repo.createBranch(name: "--force", startPoint: "refs/remotes/origin/feature/nested"); XCTFail("Option-shaped branch must be rejected") } catch { }
    }

    func testLocalRemoteFetchPullPushAndDivergence() async throws {
        let (url, repo) = try await fixture()
        let networkRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let remote = networkRoot.appendingPathComponent("remote.git")
        let peer = networkRoot.appendingPathComponent("peer")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: networkRoot) }
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        _ = try await GitProcess.run(at: remote, arguments: ["init", "--bare", "-b", "main"])
        try "base\n".write(to: url.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["shared.txt"]); try await repo.commit(message: "Initial remote")
        _ = try await GitProcess.run(at: url, arguments: ["remote", "add", "origin", remote.path])
        _ = try await GitProcess.run(at: url, arguments: ["push", "-u", "origin", "main"])
        _ = try await GitProcess.run(at: url, arguments: ["clone", remote.path, peer.path])
        _ = try await GitProcess.run(at: peer, arguments: ["config", "user.name", "Peer"])
        _ = try await GitProcess.run(at: peer, arguments: ["config", "user.email", "peer@example.invalid"])
        let peerRepo = try await GitRepository.open(peer)
        for arguments in [["config", "pull.ff", "only"], ["config", "pull.rebase", "true"], ["config", "merge.autostash", "true"], ["config", "core.editor", "/usr/bin/false"]] {
            _ = try await GitProcess.run(at: url, arguments: arguments)
        }
        try "peer\n".write(to: peer.appendingPathComponent("peer.txt"), atomically: true, encoding: .utf8)
        try await peerRepo.stage(paths: ["peer.txt"]); try await peerRepo.commit(message: "Peer remote commit")
        try await peerRepo.push()
        try await repo.fetch()
        let afterFetch = try await repo.log()
        XCTAssertTrue(afterFetch.contains { $0.subject == "Peer remote commit" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("peer.txt").path))
        try await repo.pull()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("peer.txt").path))
        let fastForward = try await repo.log(limit: 1, ref: "HEAD")
        XCTAssertEqual(fastForward.first?.subject, "Peer remote commit")
        XCTAssertEqual(fastForward.first?.parents.count, 1)
        try "local\n".write(to: url.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["local.txt"]); try await repo.commit(message: "Local pushed commit")
        try await repo.push(); try await peerRepo.pull()
        XCTAssertTrue(FileManager.default.fileExists(atPath: peer.appendingPathComponent("local.txt").path))
        try "local fork\n".write(to: url.appendingPathComponent("fork.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["fork.txt"]); try await repo.commit(message: "Local divergence")
        try "peer fork\n".write(to: peer.appendingPathComponent("peer-fork.txt"), atomically: true, encoding: .utf8)
        try await peerRepo.stage(paths: ["peer-fork.txt"]); try await peerRepo.commit(message: "Remote divergence")
        try await peerRepo.push()
        let localTip = try await GitProcess.run(at: url, arguments: ["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let remoteTip = try await GitProcess.run(at: peer, arguments: ["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try await repo.pull()
        let head = try await repo.log(limit: 1, ref: "HEAD")
        XCTAssertEqual(head.first?.parents, [remoteTip])
        XCTAssertNotEqual(head.first?.hash, localTip)
        XCTAssertEqual(head.first?.subject, "Local divergence")
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("fork.txt"), encoding: .utf8), "local fork\n")
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("peer-fork.txt"), encoding: .utf8), "peer fork\n")
        let configuredFF = try await GitProcess.run(at: url, arguments: ["config", "pull.ff"]).text
        let configuredRebase = try await GitProcess.run(at: url, arguments: ["config", "pull.rebase"]).text
        XCTAssertEqual(configuredFF, "only\n"); XCTAssertEqual(configuredRebase, "true\n")

        try "remote edit\n".write(to: peer.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try await peerRepo.stage(paths: ["shared.txt"]); try await peerRepo.commit(message: "Conflicting remote edit")
        try await peerRepo.push()
        let shared = url.appendingPathComponent("shared.txt")
        try "unsaved draft\n".write(to: shared, atomically: true, encoding: .utf8)
        let incomingTip = try await peerRepo.workflowRevision("HEAD")
        let recovered = try await repo.runNetwork(.pull, progress: { _ in })
        XCTAssertEqual(recovered.pullOutcome?.conflicts, ["shared.txt"])
        let savedDraft = try XCTUnwrap(recovered.pullOutcome?.stashHash)
        let savedContents = try await repo.workflowRead(["show", savedDraft + ":shared.txt"])
        XCTAssertEqual(savedContents, "unsaved draft\n")
        let afterRecovery = try await repo.log(limit: 1, ref: "HEAD")
        XCTAssertEqual(afterRecovery.first?.parents, [incomingTip])
        XCTAssertEqual(afterRecovery.first?.subject, "Local divergence")
        let restoredConflict = try String(contentsOf: shared, encoding: .utf8)
        XCTAssertTrue(restoredConflict.contains("<<<<<<<")); XCTAssertTrue(restoredConflict.contains("unsaved draft")); XCTAssertTrue(restoredConflict.contains("remote edit"))
        let configuredAutoStash = try await repo.workflowRead(["config", "merge.autostash"])
        XCTAssertEqual(configuredAutoStash, "true\n")

        try "local edit\n".write(to: shared, atomically: true, encoding: .utf8)
        let resolved = try await repo.fileComparison(path: "shared.txt")
        try await repo.markResolved(path: "shared.txt", expected: resolved.worktree)
        try await repo.commit(message: "Conflicting local edit")
        try "another remote edit\n".write(to: peer.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try await peerRepo.stage(paths: ["shared.txt"]); try await peerRepo.commit(message: "Another conflicting remote edit")
        try await peerRepo.push()
        let conflicted = try await repo.runNetwork(.pull, progress: { _ in })
        XCTAssertEqual(conflicted.pullOutcome?.conflicts, ["shared.txt"])
        XCTAssertNil(conflicted.pullOutcome?.stashHash)
        let files = try await repo.status()
        XCTAssertTrue(files.contains { $0.path == "shared.txt" && $0.isConflict })
        let mergedRemote = try await GitProcess.run(at: url, arguments: ["rev-parse", "HEAD~1"]).text
        let conflictingRemote = try await GitProcess.run(at: peer, arguments: ["rev-parse", "HEAD"]).text
        XCTAssertEqual(mergedRemote, conflictingRemote)
        let conflict = try String(contentsOf: shared, encoding: .utf8)
        XCTAssertTrue(conflict.contains("<<<<<<<")); XCTAssertTrue(conflict.contains("local edit")); XCTAssertTrue(conflict.contains("remote edit"))
    }

}
