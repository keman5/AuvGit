import XCTest
@testable import GitCore

final class FetchOutcomeTests: XCTestCase {
    private func fixture() async throws -> (root: URL, producer: URL, repository: GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let remote = root.appendingPathComponent("remote.git"), producer = root.appendingPathComponent("producer")
        _ = try await GitProcess.run(at: root, arguments: ["init", "--bare", "--initial-branch=dev", remote.path])
        _ = try await GitProcess.run(at: root, arguments: ["clone", remote.path, producer.path])
        _ = try await GitProcess.run(at: producer, arguments: ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "base"])
        _ = try await GitProcess.run(at: producer, arguments: ["push", "origin", "HEAD"])
        let local = root.appendingPathComponent("local")
        _ = try await GitProcess.run(at: root, arguments: ["clone", remote.path, local.path])
        _ = try await GitProcess.run(at: local, arguments: ["branch", "-m", "main"])
        return (root, producer, GitRepository(url: local))
    }

    func testFetchAllReportsDeletedUpstreamEvenWhenStaleTrackingRefIsRetained() async throws {
        let key = "auvgit.network.fetchPrune", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await GitProcess.run(at: f.producer, arguments: ["push", "origin", "HEAD:refs/heads/main"])
        _ = try await GitProcess.run(at: f.producer, arguments: ["config", "--file", f.root.appendingPathComponent("remote.git/config").path, "receive.denyDeleteCurrent", "ignore"])
        _ = try await GitProcess.run(at: f.producer, arguments: ["push", "origin", ":refs/heads/dev"])
        let head = try await f.repository.workflowRevision("HEAD")
        try Data("keep my draft".utf8).write(to: f.repository.url.appendingPathComponent("draft"))
        let outcome = try await f.repository.fetchAllRemoteBranches(remote: "origin")
        XCTAssertEqual(outcome.addedBranches, ["origin/main"])
        let missing = try XCTUnwrap(outcome.missingUpstream)
        XCTAssertEqual(missing.localBranch, "main")
        XCTAssertEqual(missing.remote, "origin")
        XCTAssertEqual(missing.mergeRef, "refs/heads/dev")
        XCTAssertEqual(missing.availableBranches, ["origin/main"])
        let stale = try await f.repository.workflowRevision("refs/remotes/origin/dev")
        XCTAssertEqual(stale, head)
        let repeated = try await f.repository.fetchAllRemoteBranches(remote: "origin")
        XCTAssertTrue(repeated.addedBranches.isEmpty)
        XCTAssertNotNil(repeated.missingUpstream, "Repeated successful fetches must not hide a broken upstream")
        let unchanged = try await f.repository.workflowRead(["config", "--get", "branch.main.merge"])
        XCTAssertEqual(unchanged.trimmingCharacters(in: .newlines), "refs/heads/dev")
        try await f.repository.repairUpstream(missing, trackingBranch: "origin/main")
        let repaired = try await f.repository.workflowRead(["config", "--get", "branch.main.merge"])
        XCTAssertEqual(repaired.trimmingCharacters(in: .newlines), "refs/heads/main")
        let after = try await f.repository.workflowRevision("HEAD")
        XCTAssertEqual(after, head)
        XCTAssertEqual(try String(contentsOf: f.repository.url.appendingPathComponent("draft"), encoding: .utf8), "keep my draft")
    }

    func testFetchAllPrunesDeletedTrackingRefsWhenEnabledAndRejectsStaleRepair() async throws {
        let key = "auvgit.network.fetchPrune", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await GitProcess.run(at: f.producer, arguments: ["push", "origin", "HEAD:refs/heads/main"])
        _ = try await GitProcess.run(at: f.producer, arguments: ["--git-dir=" + f.root.appendingPathComponent("remote.git").path, "symbolic-ref", "HEAD", "refs/heads/main"])
        _ = try await GitProcess.run(at: f.producer, arguments: ["push", "origin", ":refs/heads/dev"])
        let outcome = try await f.repository.fetchAllRemoteBranches(remote: "origin")
        XCTAssertEqual(outcome.prunedBranches, ["origin/dev"])
        let missing = try XCTUnwrap(outcome.missingUpstream)
        _ = try await GitProcess.run(at: f.repository.url, arguments: ["config", "branch.main.merge", "refs/heads/main"])
        do { try await f.repository.repairUpstream(missing, trackingBranch: "origin/main"); XCTFail("Stale repair accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("upstream changed")) }
    }

    func testFetchingAnotherRemoteDoesNotReportAnUncheckedUpstreamAsMissing() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await GitProcess.run(at: f.repository.url, arguments: ["remote", "add", "other", f.root.appendingPathComponent("remote.git").path])
        _ = try await GitProcess.run(at: f.repository.url, arguments: ["config", "branch.main.merge", "refs/heads/not-there"])
        let outcome = try await f.repository.fetchAllRemoteBranches(remote: "other")
        XCTAssertNil(outcome.missingUpstream)
        XCTAssertNil(outcome.upstreamCheckFailure)
    }

    func testUpstreamVerificationFailureIsReportedWithoutChangingSuccessfulFetchToFailure() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let snapshot = try await f.repository.fetchTrackingSnapshot()
        _ = try await GitProcess.run(at: f.repository.url, arguments: ["remote", "set-url", "origin", f.root.appendingPathComponent("missing.git").path])
        let outcome = try await f.repository.fetchOutcome(before: snapshot, credential: nil)
        XCTAssertNotNil(outcome.upstreamCheckFailure)
        XCTAssertNil(outcome.missingUpstream)
    }

    func testOrdinaryFetchReportsUpdatesThenExplicitlyReportsNoChanges() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await GitProcess.run(at: f.producer, arguments: ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "next"])
        _ = try await GitProcess.run(at: f.producer, arguments: ["push", "origin", "HEAD"])
        let first = try await f.repository.runNetwork(.fetch, progress: { _ in })
        let changed = try XCTUnwrap(first.fetchOutcome)
        XCTAssertEqual(changed.updatedBranches, ["origin/dev"])
        XCTAssertNil(changed.missingUpstream, "A local rename alone must not invalidate a live upstream")
        let second = try await f.repository.runNetwork(.fetch, progress: { _ in })
        let unchanged = try XCTUnwrap(second.fetchOutcome)
        XCTAssertTrue(unchanged.addedBranches.isEmpty)
        XCTAssertTrue(unchanged.updatedBranches.isEmpty)
        XCTAssertTrue(unchanged.prunedBranches.isEmpty)
        XCTAssertNil(unchanged.missingUpstream)
    }

    func testFailedFetchDoesNotReturnSuccessOrRewriteTracking() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await GitProcess.run(at: f.repository.url, arguments: ["remote", "set-url", "origin", f.root.appendingPathComponent("missing.git").path])
        do { _ = try await f.repository.fetchAllRemoteBranches(remote: "origin"); XCTFail("Expected transport failure") }
        catch { XCTAssertTrue(error is GitError) }
        let merge = try await f.repository.workflowRead(["config", "--get", "branch.main.merge"])
        XCTAssertEqual(merge.trimmingCharacters(in: .newlines), "refs/heads/dev")
    }
}
