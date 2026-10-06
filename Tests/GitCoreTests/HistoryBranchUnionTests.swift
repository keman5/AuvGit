import XCTest
@testable import GitCore

final class HistoryBranchUnionTests: XCTestCase {
    func testCheckedRefsUnionDeduplicatesAndPreservesCollidingFullNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(url: root)
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"]] { _ = try await GitProcess.run(at: root, arguments: args) }
        func commit(_ name: String) async throws -> String {
            try name.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
            try await repo.stage(paths: [name]); try await repo.commit(message: name)
            return try await repo.workflowRevision("HEAD")
        }
        let base = try await commit("base")
        _ = try await GitProcess.run(at: root, arguments: ["checkout", "-b", "origin/topic"])
        let local = try await commit("local")
        _ = try await GitProcess.run(at: root, arguments: ["checkout", "main"])
        let remote = try await commit("remote")
        _ = try await GitProcess.run(at: root, arguments: ["update-ref", "refs/remotes/origin/topic", remote])
        let refs = ["refs/heads/origin/topic", "refs/remotes/origin/topic"]
        let union = try await repo.log(refs: refs + refs)
        XCTAssertEqual(Set(union.map(\.hash)), [base, local, remote])
        XCTAssertEqual(union.count, 3)
        let localOnly = try await repo.log(refs: [refs[0]])
        XCTAssertEqual(Set(localOnly.map(\.hash)), [base, local])
        let empty = try await repo.log(refs: [])
        XCTAssertTrue(empty.isEmpty)
        let containing = try await repo.branchesContaining(commit: local)
        XCTAssertTrue(containing.contains(refs[0])); XCTAssertFalse(containing.contains(refs[1]))
        let first = try await repo.log(limit: 1, refs: refs)
        let rest = try await repo.log(limit: 2, skip: 1, refs: refs)
        XCTAssertEqual(first + rest, union)
    }
    func testRecyclableScopeExcludesReachableCommitsAndUnionsStashes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(url: root)
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"]] { _ = try await GitProcess.run(at: root, arguments: args) }
        _ = try await GitProcess.run(at: root, arguments: ["commit", "--allow-empty", "-m", "base"])
        let base = try await repo.workflowRevision("HEAD")
        _ = try await GitProcess.run(at: root, arguments: ["checkout", "-b", "discarded"])
        _ = try await GitProcess.run(at: root, arguments: ["commit", "--allow-empty", "-m", "discarded"])
        let discarded = try await repo.workflowRevision("HEAD")
        _ = try await GitProcess.run(at: root, arguments: ["checkout", "main"])
        _ = try await GitProcess.run(at: root, arguments: ["branch", "-D", "discarded"])
        let recycled = try await repo.log(refs: [], includeRecyclable: true)
        XCTAssertEqual(recycled.map(\.hash), [discarded])
        try "pending".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        _ = try await GitProcess.run(at: root, arguments: ["stash", "push", "--include-untracked", "-m", "pending"])
        let stash = try await repo.workflowRevision("stash@{0}")
        let union = try await repo.log(refs: ["HEAD", "stash@{0}"], includeRecyclable: true)
        XCTAssertTrue(Set(union.map(\.hash)).isSuperset(of: [base, discarded, stash]))
        XCTAssertEqual(union.count, Set(union.map(\.hash)).count)
        let first = try await repo.log(limit: 1, refs: ["HEAD", "stash@{0}"], includeRecyclable: true)
        let rest = try await repo.log(limit: 100, skip: 1, refs: ["HEAD", "stash@{0}"], includeRecyclable: true)
        XCTAssertEqual(first + rest, union)
        _ = try await GitProcess.run(at: root, arguments: ["tag", "rescued", discarded])
        let rescued = try await repo.recyclableCommitHashes()
        XCTAssertFalse(rescued.contains(discarded))
    }

    func testDefaultStashUnionIncludesOlderEntriesWithoutIndexOrUntrackedParents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(url: root)
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"], ["commit", "--allow-empty", "-m", "base"]] { _ = try await GitProcess.run(at: root, arguments: args) }
        let base = try await repo.workflowRevision("HEAD")
        for name in ["older", "latest"] {
            try name.write(to: root.appendingPathComponent("pending"), atomically: true, encoding: .utf8)
            _ = try await GitProcess.run(at: root, arguments: ["stash", "push", "--include-untracked", "-m", name])
        }
        let stashes = try await repo.stashes()
        XCTAssertEqual(stashes.count, 2)
        let hashes = stashes.map(\.hash)
        let main = try await repo.log(ref: "HEAD", firstParent: true, stashHashes: hashes)
        XCTAssertEqual(Set(main.map(\.hash)), Set(hashes).union([base]))
        let independent = try await repo.log(refs: ["HEAD"], stashHashes: hashes)
        XCTAssertEqual(Set(independent.map(\.hash)), Set(hashes).union([base]))
        let first = try await repo.log(limit: 1, refs: ["HEAD"], stashHashes: hashes)
        let rest = try await repo.log(limit: 100, skip: 1, refs: ["HEAD"], stashHashes: hashes)
        XCTAssertEqual(first + rest, independent)
        let stashOnly = try await repo.log(refs: [], stashHashes: hashes)
        XCTAssertEqual(Set(stashOnly.map(\.hash)), Set(hashes))
        let branchOnly = try await repo.log(refs: ["HEAD"])
        XCTAssertEqual(branchOnly.map(\.hash), [base])
    }

}
