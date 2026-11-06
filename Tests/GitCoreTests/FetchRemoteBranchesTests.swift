import XCTest
@testable import GitCore

final class FetchRemoteBranchesTests: XCTestCase {
    func testFetchAllHeadsOverridesSingleBranchCloneAndKeepsFutureBranchesTracked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote.git"), producer = root.appendingPathComponent("producer")
        _ = try await GitProcess.run(at: root, arguments: ["init", "--bare", "--initial-branch=main", remote.path])
        _ = try await GitProcess.run(at: root, arguments: ["clone", remote.path, producer.path])
        _ = try await GitProcess.run(at: producer, arguments: ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "base"])
        for name in ["main", "feature/one", "feature/two"] {
            _ = try await GitProcess.run(at: producer, arguments: ["push", "origin", "HEAD:refs/heads/" + name])
        }
        let clone = root.appendingPathComponent("clone")
        _ = try await GitProcess.run(at: root, arguments: ["clone", "--single-branch", "--branch", "main", remote.path, clone.path])
        let repo = GitRepository(url: clone)
        let head = try await repo.workflowRevision("HEAD")
        try "keep".write(to: clone.appendingPathComponent("draft"), atomically: true, encoding: .utf8)
        try await repo.fetchAllRemoteBranches(remote: "origin")
        let remaining = try await repo.unfetchedRemoteBranches(remote: "origin")
        XCTAssertTrue(remaining.isEmpty)
        let after = try await repo.workflowRevision("HEAD")
        XCTAssertEqual(after, head)
        XCTAssertEqual(try String(contentsOf: clone.appendingPathComponent("draft"), encoding: .utf8), "keep")
        let localHeads = try await repo.workflowRead(["for-each-ref", "--format=%(refname)", "refs/heads/"])
        XCTAssertEqual(localHeads.trimmingCharacters(in: .newlines), "refs/heads/main")
        _ = try await GitProcess.run(at: producer, arguments: ["push", "origin", "HEAD:refs/heads/feature/later"])
        _ = try await repo.runNetwork(.fetch, remoteName: "origin", progress: { _ in })
        let later = try await repo.workflowRevision("refs/remotes/origin/feature/later")
        XCTAssertEqual(later, head)
        try await repo.fetchAllRemoteBranches(remote: "origin")
        let mappings = try await repo.workflowRead(["config", "--get-all", "remote.origin.fetch"])
        XCTAssertEqual(mappings.trimmingCharacters(in: .newlines), "+refs/heads/*:refs/remotes/origin/*")
        do {
            try await repo.fetchAllRemoteBranches(remote: "missing")
            XCTFail("Unknown remote accepted")
        } catch { XCTAssertTrue(error is GitError) }
    }

    func testSelectedHeadsExtendSingleBranchCloneWithoutChangingWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote.git"), producer = root.appendingPathComponent("producer")
        _ = try await GitProcess.run(at: root, arguments: ["init", "--bare", "--initial-branch=main", remote.path])
        _ = try await GitProcess.run(at: root, arguments: ["clone", remote.path, producer.path])
        _ = try await GitProcess.run(at: producer, arguments: ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "base"])
        for name in ["main", "feature/one", "feature/two"] {
            _ = try await GitProcess.run(at: producer, arguments: ["push", "origin", "HEAD:refs/heads/" + name])
        }
        let clone = root.appendingPathComponent("clone")
        _ = try await GitProcess.run(at: root, arguments: ["clone", "--single-branch", "--branch", "main", remote.path, clone.path])
        let repo = GitRepository(url: clone)
        let head = try await repo.workflowRevision("HEAD")
        try "keep".write(to: clone.appendingPathComponent("draft"), atomically: true, encoding: .utf8)
        let missing = try await repo.unfetchedRemoteBranches(remote: "origin")
        XCTAssertEqual(missing, ["feature/one", "feature/two"])
        try await repo.fetchRemoteBranches(remote: "origin", branches: ["feature/one", "feature/one"])
        let remaining = try await repo.unfetchedRemoteBranches(remote: "origin")
        XCTAssertEqual(remaining, ["feature/two"])
        let after = try await repo.workflowRevision("HEAD")
        XCTAssertEqual(after, head)
        XCTAssertEqual(try String(contentsOf: clone.appendingPathComponent("draft"), encoding: .utf8), "keep")
        let refspecs = try await repo.workflowRead(["config", "--get-all", "remote.origin.fetch"])
        XCTAssertEqual(refspecs.split(separator: "\n").filter { $0.contains("feature/one") }.count, 1)
        XCTAssertFalse(refspecs.contains("feature/two"))
        // A later ordinary fetch must update the newly tracked branch too.
        _ = try await GitProcess.run(at: producer, arguments: ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "next"])
        _ = try await GitProcess.run(at: producer, arguments: ["push", "origin", "HEAD:refs/heads/feature/one"])
        _ = try await repo.runNetwork(.fetch, progress: { _ in })
        let fetched = try await repo.workflowRevision("refs/remotes/origin/feature/one")
        let advertised = try await GitRepository(url: producer).workflowRevision("HEAD")
        XCTAssertEqual(fetched, advertised)
        for invalid in ["../escape", "*", "main:refs/heads/main", "--all"] {
            do { try await repo.fetchRemoteBranches(remote: "origin", branches: [invalid]); XCTFail("Accepted invalid branch") }
            catch { XCTAssertTrue(error is GitError) }
        }
        let before = try await repo.workflowRead(["config", "--get-all", "remote.origin.fetch"])
        let started = Date()
        do { try await repo.fetchRemoteBranches(remote: "origin", branches: ["missing"]); XCTFail("Missing branch accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("couldn't find remote ref"), error.localizedDescription) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "Git must stop its transport helper promptly after a missing-ref error")
        let unchanged = try await repo.workflowRead(["config", "--get-all", "remote.origin.fetch"])
        XCTAssertEqual(unchanged, before, "Failed fetch must not persist new tracking rules")
    }
}
