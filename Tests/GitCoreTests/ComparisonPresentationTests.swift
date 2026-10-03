import XCTest
@testable import GitCore

final class ComparisonPresentationTests: XCTestCase {
    private func fixture() async throws -> (URL, GitRepository) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"], ["config", "core.filemode", "true"]] { _ = try await GitProcess.run(at: dir, arguments: args) }
        return (dir, GitRepository(url: dir))
    }
    func testRealGitChangeStatesPreserveCurrentResult() async throws {
        let (dir, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["unstaged", "staged", "both", "mode", "old", "deleted"] { try Data("\(name) head\n".utf8).write(to: dir.appendingPathComponent(name)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent("mode").path)
        try await repo.stage(paths: ["unstaged", "staged", "both", "mode", "old", "deleted"]); try await repo.commit(message: "base")
        try Data("working\n".utf8).write(to: dir.appendingPathComponent("unstaged"))
        try Data("staged result\n".utf8).write(to: dir.appendingPathComponent("staged")); try await repo.stage(paths: ["staged"])
        try Data("index\n".utf8).write(to: dir.appendingPathComponent("both")); try await repo.stage(paths: ["both"])
        try Data("existing unsaved result\n".utf8).write(to: dir.appendingPathComponent("both"))
        try Data("untracked result\n".utf8).write(to: dir.appendingPathComponent("untracked"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("mode").path)
        try await repo.stage(paths: ["mode"])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent("mode").path)
        try FileManager.default.moveItem(at: dir.appendingPathComponent("old"), to: dir.appendingPathComponent("new"))
        try await repo.stage(paths: ["old", "new"])
        try FileManager.default.removeItem(at: dir.appendingPathComponent("deleted")); try await repo.stage(paths: ["deleted"])
        let unstaged = try await repo.fileComparison(path: "unstaged")
        XCTAssertEqual(unstaged.presentation.columns, [.index, .worktree]); XCTAssertEqual(unstaged.worktree.text, "working\n")
        let staged = try await repo.fileComparison(path: "staged")
        XCTAssertEqual(staged.presentation.columns, [.head, .worktree]); XCTAssertEqual(staged.worktree.text, "staged result\n")
        let both = try await repo.fileComparison(path: "both")
        XCTAssertEqual(both.presentation.columns, [.head, .worktree, .index]); XCTAssertEqual(both.worktree.text, "existing unsaved result\n")
        let untracked = try await repo.fileComparison(path: "untracked")
        XCTAssertEqual(untracked.presentation.columns, [.index, .worktree]); XCTAssertFalse(untracked.index.exists)
        let mode = try await repo.fileComparison(path: "mode")
        XCTAssertEqual(mode.head.data, mode.index.data); XCTAssertEqual(mode.index.data, mode.worktree.data)
        XCTAssertEqual(mode.presentation.columns, [.head, .worktree, .index], "mode-only staged/unstaged must use status")
        let renamed = try await repo.fileComparison(path: "new")
        XCTAssertEqual(renamed.status?.originalPath, "old"); XCTAssertEqual(renamed.presentation.columns, [.head, .worktree])
        try Data("head\nrename worktree change\n".utf8).write(to: dir.appendingPathComponent("new"))
        let renamedBoth = try await repo.fileComparison(path: "new")
        XCTAssertEqual(renamedBoth.presentation.columns, [.head, .worktree, .index]); XCTAssertEqual(renamedBoth.status?.originalPath, "old")
        let deleted = try await repo.fileComparison(path: "deleted")
        XCTAssertFalse(deleted.index.exists); XCTAssertFalse(deleted.worktree.exists); XCTAssertEqual(deleted.presentation.columns, [.head, .worktree])
        for snapshot in [unstaged, staged, both, untracked, mode, renamed, renamedBoth, deleted] { XCTAssertEqual(snapshot.presentation.editableRevision, .worktree) }
    }
    func testRealUUConflictUsesOursCurrentWorktreeAndTheirs() async throws {
        let (dir, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("conflict")
        try Data("base\n".utf8).write(to: file); try await repo.stage(paths: ["conflict"]); try await repo.commit(message: "base")
        _ = try await GitProcess.run(at: dir, arguments: ["switch", "-c", "other"])
        try Data("theirs\n".utf8).write(to: file); try await repo.stage(paths: ["conflict"]); try await repo.commit(message: "theirs")
        _ = try await GitProcess.run(at: dir, arguments: ["switch", "main"])
        try Data("ours\n".utf8).write(to: file); try await repo.stage(paths: ["conflict"]); try await repo.commit(message: "ours")
        _ = try await GitProcess.run(at: dir, arguments: ["merge", "other"], allowedCodes: [1])
        try Data("existing partially resolved worktree\n".utf8).write(to: file)
        let before = try Data(contentsOf: file), snapshot = try await repo.fileComparison(path: "conflict")
        XCTAssertEqual(snapshot.status?.indexStatus, "U"); XCTAssertEqual(snapshot.status?.worktreeStatus, "U")
        XCTAssertEqual(snapshot.presentation.columns, [.ours, .worktree, .theirs]); XCTAssertEqual(snapshot.presentation.layout, .three)
        XCTAssertEqual(snapshot.ours?.text, "ours\n"); XCTAssertEqual(snapshot.theirs?.text, "theirs\n")
        XCTAssertEqual(snapshot.worktree.text, "existing partially resolved worktree\n")
        XCTAssertEqual(try Data(contentsOf: file), before)
        let index = try await GitProcess.run(at: dir, arguments: ["ls-files", "-u", "--", "conflict"]).text
        XCTAssertEqual(index.split(separator: "\n").count, 3, "reading presentation must not stage or resolve")
    }
}
