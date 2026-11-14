import XCTest
@testable import GitCore

final class HistoryComparisonTests: XCTestCase {
    private func fixture() async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-comparison-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "user.name", "History"], ["config", "user.email", "history@example.invalid"], ["config", "commit.gpgsign", "false"]] {
            _ = try await GitProcess.run(at: root, arguments: args)
        }
        return root
    }
    private func write(_ value: String, _ path: String, at root: URL) throws {
        try value.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    private func commit(_ name: String, at root: URL) async throws -> String {
        _ = try await GitProcess.run(at: root, arguments: ["add", "-A"])
        _ = try await GitProcess.run(at: root, arguments: ["commit", "--allow-empty", "-m", name])
        return try await GitRepository(url: root).workflowRevision("HEAD")
    }

    func testEndpointRenameAdditionDeletionAndExplicitReverse() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(url: root)
        let old = "odd[1]*.txt", new = ":(glob)renamed*.txt"
        try write("original\n", old, at: root); try write("deleted\n", "deleted", at: root)
        let base = try await commit("base", at: root)
        try FileManager.default.moveItem(at: root.appendingPathComponent(old), to: root.appendingPathComponent(new))
        try FileManager.default.removeItem(at: root.appendingPathComponent("deleted"))
        try write("added\n", "added", at: root)
        let tip = try await commit("tip", at: root)
        let range = try await repo.historyComparisonRange(ids: [base, tip], orderedCommitIDs: [base, tip])
        XCTAssertEqual(range, HistoryComparisonRange(from: .commit(base), to: .commit(tip)))
        let files = try await repo.comparisonFiles(from: .commit(base), to: .commit(tip))
        let renamed = try XCTUnwrap(files.first { $0.path == new })
        XCTAssertEqual(renamed.originalPath, old); XCTAssertTrue(renamed.status.hasPrefix("R"))
        let snapshot = try await repo.comparisonPreview(target: range!.target(for: renamed))
        XCTAssertEqual(snapshot.head.text, "original\n"); XCTAssertEqual(snapshot.worktree.text, "original\n")
        XCTAssertEqual(files.first { $0.path == "added" }?.status, "A")
        XCTAssertEqual(files.first { $0.path == "deleted" }?.status, "D")
        let reverse = try await repo.comparisonFiles(from: .commit(tip), to: .commit(base))
        XCTAssertEqual(reverse.first { $0.path == old }?.originalPath, new)
        XCTAssertEqual(reverse.first { $0.path == "added" }?.status, "D")
        XCTAssertEqual(reverse.first { $0.path == "deleted" }?.status, "A")
        try write("index\n", new, at: root); try await repo.stage(paths: [new])
        try write("working\n", new, at: root)
        let endpoints: [(HistoryEndpoint, HistoryEndpoint, String, String)] = [
            (.commit(tip), .index, "original\n", "index\n"),
            (.index, .workingTree, "index\n", "working\n"),
            (.workingTree, .commit(tip), "working\n", "original\n")
        ]
        for (from, to, left, right) in endpoints {
            let preview = try await repo.comparisonPreview(target: .between(from: from, to: to, path: new))
            XCTAssertEqual(preview.head.text, left); XCTAssertEqual(preview.worktree.text, right)
        }
        let virtualRange = try await repo.historyComparisonRange(ids: [HistoryEndpoint.index.id, HistoryEndpoint.workingTree.id], orderedCommitIDs: [tip, base])
        XCTAssertEqual(virtualRange, HistoryComparisonRange(from: .index, to: .workingTree))
    }

    func testHistoricalPathRecreatedUntrackedUsesActualEndpointContent() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(url: root)
        try write("same\n", "file", at: root)
        let base = try await commit("base", at: root)
        _ = try await GitProcess.run(at: root, arguments: ["rm", "--cached", "--", "file"])
        let unchanged = try await repo.comparisonFiles(from: .commit(base), to: .workingTree)
        XCTAssertTrue(unchanged.isEmpty)
        try write("different\n", "file", at: root)
        let changed = try await repo.comparisonFiles(from: .commit(base), to: .workingTree)
        XCTAssertEqual(changed, [GitCommitFile(path: "file", status: "M")])
        let preview = try await repo.comparisonPreview(target: .between(from: .commit(base), to: .workingTree, path: "file"))
        XCTAssertEqual(preview.head.text, "same\n"); XCTAssertEqual(preview.worktree.text, "different\n")
        let patch = try await repo.displayDiff(target: .between(from: .commit(base), to: .workingTree, path: "file"))
        XCTAssertTrue(patch.text.contains("-same")); XCTAssertTrue(patch.text.contains("+different"))
        let reverse = try await repo.comparisonFiles(from: .workingTree, to: .commit(base))
        XCTAssertEqual(reverse, [GitCommitFile(path: "file", status: "M")])
        let index = try await repo.comparisonFiles(from: .commit(base), to: .index)
        XCTAssertEqual(index, [GitCommitFile(path: "file", status: "D")])
    }

    func testFilteredGraphBridgesAncestorsAndProjectsQualifiedRefs() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(url: root)
        let base = try await commit("keep base", at: root)
        let hidden = try await commit("hidden", at: root)
        let middle = try await commit("keep middle", at: root)
        _ = try await commit("hidden tip", at: root)
        let filtered = try await repo.log(search: "keep")
        let row = try XCTUnwrap(filtered.first { $0.hash == middle })
        XCTAssertEqual(row.parents, [hidden]); XCTAssertEqual(row.graphParents, [base])
        XCTAssertTrue(row.refs.contains("refs/heads/main~"))
        XCTAssertEqual(filtered.last?.hash, base)
        XCTAssertEqual(filtered.last?.graphParents, [])
        let firstPage = try await repo.log(limit: 1, search: "keep")
        XCTAssertEqual(firstPage.first?.graphParents, [hidden])
        let secondPage = try await repo.log(limit: 1, skip: 1, search: "keep")
        let combined = try await repo.projectedHistory(firstPage + secondPage)
        XCTAssertEqual(combined.first?.graphParents, [base])
    }

    func testGraphCommandsRejectStalePreviewVirtualIDsAndCheckedOutBranchMoves() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(url: root)
        let base = try await commit("base", at: root)
        _ = try await GitProcess.run(at: root, arguments: ["branch", "source", base])
        let tip = try await commit("tip", at: root)
        let requests: [HistoryGraphCommand] = [
            .cherryPick(commits: [base], target: base, expectedHead: base),
            .cherryPick(commits: [base], target: base, expectedHead: tip),
            .reset(target: HistoryEndpoint.index.id, expectedHead: tip),
            .moveBranch(name: "refs/heads/main", target: base, expectedSource: tip),
            .moveBranch(name: "refs/heads/source", target: base, expectedSource: tip)
        ]
        for request in requests {
            do { try await repo.executeHistoryGraphCommand(request); XCTFail("Expected stale/unsupported graph operation rejection") }
            catch { XCTAssertTrue(error is GitError) }
            let head = try await repo.workflowRevision("HEAD")
            XCTAssertEqual(head, tip)
        }
        try await repo.executeHistoryGraphCommand(.moveBranch(name: "refs/heads/source", target: tip, expectedSource: base))
        let moved = try await repo.workflowRevision("refs/heads/source")
        XCTAssertEqual(moved, tip)
    }

    func testOverlapCountsRawChangedPositionsAndDistinguishesDisjointLines() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(url: root)
        try write("one\ntwo\nthree\n", "file", at: root)
        let base = try await commit("base", at: root)
        try write("ONE\ntwo\nthree\n", "file", at: root)
        let selected = try await commit("selected", at: root)
        _ = try await GitProcess.run(at: root, arguments: ["checkout", "-B", "disjoint", base])
        try write("one\nTWO\nthree\n", "file", at: root)
        let disjoint = try await commit("disjoint", at: root)
        _ = try await GitProcess.run(at: root, arguments: ["checkout", "-B", "overlapping", base])
        try write("different first line\ntwo\nthree\n", "file", at: root)
        let overlapping = try await commit("overlapping", at: root)
        let scores = try await repo.historyOverlap(selected: selected, candidates: [disjoint, overlapping])
        XCTAssertEqual(scores[disjoint], 0)
        XCTAssertEqual(scores[overlapping], 1)
    }

    func testOldCommitCacheDecodesWithoutNewSignatureField() throws {
        let commit = GitCommit(hash: "abc", parents: [], author: "Test", date: Date(timeIntervalSince1970: 100), subject: "test", body: "test", refs: [])
        let data = try JSONEncoder().encode(commit)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "signatureStatus"); object.removeValue(forKey: "graphParents")
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(GitCommit.self, from: old)
        XCTAssertEqual(decoded.signatureStatus, "N"); XCTAssertNil(decoded.graphParents)
    }
}
