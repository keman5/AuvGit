import XCTest
@testable import GitCore

final class PullRecoveryTests: XCTestCase {
    private struct Fixture { let root: URL; let local: GitRepository; let peer: GitRepository }
    private func write(_ text: String, _ path: String = "shared", in repo: GitRepository) throws {
        try text.write(to: repo.url.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    private func commit(_ repo: GitRepository, _ message: String) async throws {
        _ = try await GitProcess.run(at: repo.url, arguments: ["add", "--all"])
        try await repo.commit(message: message)
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("auvgit-pull-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let remote = root.appendingPathComponent("remote.git")
        _ = try await GitProcess.run(at: root, arguments: ["init", "--bare", "-b", "main", remote.path])
        let local = GitRepository(url: root.appendingPathComponent("local"))
        _ = try await GitProcess.run(at: root, arguments: ["clone", remote.path, local.url.path])
        try await configure(local)
        try write("base\n", in: local); try await commit(local, "base")
        _ = try await GitProcess.run(at: local.url, arguments: ["push", "-u", "origin", "main"])
        let peer = GitRepository(url: root.appendingPathComponent("peer"))
        _ = try await GitProcess.run(at: root, arguments: ["clone", remote.path, peer.url.path])
        try await configure(peer)
        return Fixture(root: root, local: local, peer: peer)
    }
    private func configure(_ repo: GitRepository) async throws {
        for pair in [["user.name", "Test"], ["user.email", "test@example.invalid"], ["commit.gpgsign", "false"], ["pull.ff", "only"], ["pull.rebase", "true"]] {
            _ = try await GitProcess.run(at: repo.url, arguments: ["config"] + pair)
        }
    }
    func testDivergedHistoryRebasesEvenWithFastForwardOnlyConfiguration() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.local.workflowRead(["config", "pull.rebase", "false"])
        try write("local", "local", in: f.local); try await commit(f.local, "local")
        try write("remote", "remote", in: f.peer); try await commit(f.peer, "remote"); try await f.peer.push()
        let result = try await f.local.runNetwork(.pull, progress: { _ in })
        XCTAssertNil(result.pullOutcome)
        let parents = try await f.local.workflowRead(["rev-list", "--parents", "-1", "HEAD"])
        XCTAssertEqual(parents.split(whereSeparator: \.isWhitespace).count, 2)
        let localParent = try await f.local.workflowRevision("HEAD^")
        let remoteHead = try await f.peer.workflowRevision("HEAD")
        XCTAssertEqual(localParent, remoteHead)
        let subject = try await f.local.workflowRead(["log", "-1", "--format=%s"])
        XCTAssertEqual(subject, "local\n")
        XCTAssertEqual(try String(contentsOf: f.local.url.appendingPathComponent("remote"), encoding: .utf8), "remote")
    }
    func testCommittedRebaseConflictRemainsInLocalIndexInsteadOfThrowing() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try write("local\n", in: f.local); try await commit(f.local, "local")
        try write("remote\n", in: f.peer); try await commit(f.peer, "remote"); try await f.peer.push()
        let result = try await f.local.runNetwork(.pull, progress: { _ in })
        XCTAssertEqual(result.pullOutcome?.conflicts, ["shared"])
        XCTAssertNil(result.pullOutcome?.stashHash)
        let files = try await f.local.status()
        XCTAssertTrue(files.contains { $0.path == "shared" && $0.isConflict })
        XCTAssertTrue(try String(contentsOf: f.local.url.appendingPathComponent("shared"), encoding: .utf8).contains("<<<<<<<"))
    }
    func testObstructingWorktreeIsSavedThenRestoredAsLocalConflict() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try write("working\n", in: f.local)
        try write("untracked", "notes", in: f.local)
        try write("remote\n", in: f.peer); try await commit(f.peer, "remote"); try await f.peer.push()
        let result = try await f.local.runNetwork(.pull, progress: { _ in })
        XCTAssertEqual(result.pullOutcome?.conflicts, ["shared"])
        XCTAssertNotNil(result.pullOutcome?.stashHash)
        let localHead = try await f.local.workflowRevision("HEAD"), peerHead = try await f.peer.workflowRevision("HEAD")
        XCTAssertEqual(localHead, peerHead)
        let stashes = try await f.local.stashes(), files = try await f.local.status()
        XCTAssertEqual(stashes.count, 1)
        XCTAssertTrue(files.contains { $0.path == "shared" && $0.isConflict })
        XCTAssertEqual(try String(contentsOf: f.local.url.appendingPathComponent("notes"), encoding: .utf8), "untracked")
    }

    func testCleanThreeWayRestorationPreservesStagedUnstagedAndUntrackedChanges() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let base = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try write(base, in: f.local); try await commit(f.local, "lines"); try await f.local.push(); try await f.peer.pull()
        try write(base.replacingOccurrences(of: "line 1\n", with: "local first\n"), in: f.local)
        try write("index", "staged", in: f.local); try await f.local.stage(paths: ["staged"])
        try write("working", "staged", in: f.local)
        try write("notes", "notes", in: f.local)
        try write(base.replacingOccurrences(of: "line 20\n", with: "remote last\n"), in: f.peer)
        try await commit(f.peer, "remote"); try await f.peer.push()
        let result = try await f.local.runNetwork(.pull, progress: { _ in })
        XCTAssertEqual(result.pullOutcome?.conflicts, [])
        XCTAssertEqual(result.pullOutcome?.changesRestored, true)
        let text = try String(contentsOf: f.local.url.appendingPathComponent("shared"), encoding: .utf8)
        XCTAssertTrue(text.contains("local first")); XCTAssertTrue(text.contains("remote last"))
        let staged = try await f.local.workflowRead(["show", ":staged"])
        XCTAssertEqual(staged, "index")
        XCTAssertEqual(try String(contentsOf: f.local.url.appendingPathComponent("staged"), encoding: .utf8), "working")
        XCTAssertEqual(try String(contentsOf: f.local.url.appendingPathComponent("notes"), encoding: .utf8), "notes")
        let stashes = try await f.local.stashes(); XCTAssertEqual(stashes.count, 1)
    }

    func testStagedConflictFallsBackToWorktreeMergeAndKeepsRecoveryCopy() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try write("local staged\n", in: f.local); try await f.local.stage(paths: ["shared"])
        try write("remote\n", in: f.peer); try await commit(f.peer, "remote"); try await f.peer.push()
        let result = try await f.local.runNetwork(.pull, progress: { _ in })
        XCTAssertEqual(result.pullOutcome?.conflicts, ["shared"])
        let hash = try XCTUnwrap(result.pullOutcome?.stashHash)
        let saved = try await f.local.workflowRead(["show", hash + "^2:shared"])
        XCTAssertEqual(saved, "local staged\n")
    }

    func testUntrackedCollisionRetainsBothRemoteFileAndSavedLocalFile() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try write("local notes", "notes", in: f.local)
        try write("remote notes", "notes", in: f.peer); try await commit(f.peer, "remote"); try await f.peer.push()
        let result = try await f.local.runNetwork(.pull, progress: { _ in })
        let hash = try XCTUnwrap(result.pullOutcome?.stashHash)
        XCTAssertEqual(result.pullOutcome?.changesRestored, false)
        XCTAssertNotNil(result.pullOutcome?.restorationError)
        XCTAssertEqual(try String(contentsOf: f.local.url.appendingPathComponent("notes"), encoding: .utf8), "remote notes")
        let saved = try await f.local.workflowRead(["show", hash + "^3:notes"])
        XCTAssertEqual(saved, "local notes")
    }

    func testExistingRebaseConflictIsNotAbortedOrStashedByAnotherPull() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try write("local\n", in: f.local); try await commit(f.local, "local")
        try write("remote\n", in: f.peer); try await commit(f.peer, "remote"); try await f.peer.push()
        _ = try await f.local.runNetwork(.pull, progress: { _ in })
        let before = try await f.local.workflowRead(["ls-files", "--stage"])
        do { _ = try await f.local.runNetwork(.pull, progress: { _ in }); XCTFail("Existing conflict should require resolution") }
        catch { XCTAssertTrue(error.localizedDescription.contains("existing local conflicts")) }
        let after = try await f.local.workflowRead(["ls-files", "--stage"])
        let stashes = try await f.local.stashes()
        XCTAssertEqual(before, after); XCTAssertTrue(stashes.isEmpty)
    }

    func testNetworkFailureDoesNotStashDirtyWorkspace() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try write("working", in: f.local)
        _ = try await f.local.workflowRead(["remote", "set-url", "origin", f.root.appendingPathComponent("missing.git").path])
        do { _ = try await f.local.runNetwork(.pull, progress: { _ in }); XCTFail("Missing remote should fail") } catch { }
        let stashes = try await f.local.stashes(); XCTAssertTrue(stashes.isEmpty)
        XCTAssertEqual(try String(contentsOf: f.local.url.appendingPathComponent("shared"), encoding: .utf8), "working")
    }

    func testCommittedConflictAfterStashKeepsSavedWorkSeparateUntilRebaseIsResolved() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try write("local committed\n", in: f.local); try await commit(f.local, "local")
        try write("local working\n", in: f.local)
        try write("draft", "notes", in: f.local)
        try write("remote committed\n", in: f.peer); try await commit(f.peer, "remote"); try await f.peer.push()
        let result = try await f.local.runNetwork(.pull, progress: { _ in })
        let outcome = try XCTUnwrap(result.pullOutcome), hash = try XCTUnwrap(outcome.stashHash)
        XCTAssertEqual(outcome.conflicts, ["shared"]); XCTAssertFalse(outcome.changesRestored)
        let saved = try await f.local.workflowRead(["show", hash + ":shared"])
        XCTAssertEqual(saved, "local working\n")
        let savedDraft = try await f.local.workflowRead(["show", hash + "^3:notes"])
        XCTAssertEqual(savedDraft, "draft")
        XCTAssertTrue(try String(contentsOf: f.local.url.appendingPathComponent("shared"), encoding: .utf8).contains("local committed"))
    }
}
