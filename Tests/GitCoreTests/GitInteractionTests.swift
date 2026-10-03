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
}
