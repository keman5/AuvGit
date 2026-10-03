import XCTest
@testable import GitCore

final class PartialStagingTests: XCTestCase {
    func testStagedRenameKeepsRenameAndPartiallyStagesContent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for args in [["init"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"]] { _ = try await GitProcess.run(at: dir, arguments: args) }
        let repo = GitRepository(url: dir), old = dir.appendingPathComponent("old"), file = dir.appendingPathComponent("new name")
        let base = (1...20).map { "line\($0)\n" }.joined()
        try Data(base.utf8).write(to: old); try await repo.stage(paths: ["old"]); try await repo.commit(message: "base")
        try FileManager.default.moveItem(at: old, to: file); try await repo.stage(paths: ["old", "new name"])
        try Data((base + "selected\nunstaged\n").utf8).write(to: file)
        let partial = try await repo.partialStaging(path: "new name", unstage: false)
        XCTAssertNil(partial.unavailableReason)
        let selected = partial.hunks.flatMap(\.lines).first { $0.text == "+selected" }!
        try await repo.applyPartialStaging(partial, selectedLines: [selected.id])
        let state = try await repo.fileComparison(path: "new name")
        XCTAssertEqual(state.index.text, base + "selected\n"); XCTAssertEqual(state.worktree.text, base + "selected\nunstaged\n")
        let status = try await repo.status(); XCTAssertEqual(status.first { $0.path == "new name" }?.originalPath, "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        let undo = try await repo.partialStaging(path: "new name", unstage: true); XCTAssertNotNil(undo.unavailableReason)
    }
    func testNewDeletedAndPartiallyUnstagedNewFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for args in [["init"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"]] { _ = try await GitProcess.run(at: dir, arguments: args) }
        let repo = GitRepository(url: dir), path = "new space.txt", file = dir.appendingPathComponent(path)
        try Data("first\nsecond\nthird\n".utf8).write(to: file)
        let newFile = try await repo.partialStaging(path: path, unstage: false)
        XCTAssertNil(newFile.unavailableReason)
        let second = newFile.hunks.flatMap(\.lines).first { $0.text == "+second" }!
        try await repo.applyPartialStaging(newFile, selectedLines: [second.id])
        var state = try await repo.fileComparison(path: path); XCTAssertEqual(state.index.text, "second\n"); XCTAssertEqual(state.worktree.text, "first\nsecond\nthird\n")
        try await repo.stage(paths: [path])
        let undo = try await repo.partialStaging(path: path, unstage: true)
        let middle = undo.hunks.flatMap(\.lines).first { $0.text == "-second" }!
        try await repo.applyPartialStaging(undo, selectedLines: [middle.id])
        state = try await repo.fileComparison(path: path); XCTAssertEqual(state.index.text, "first\nthird\n")
        try await repo.stage(paths: [path]); try await repo.commit(message: "base")
        try FileManager.default.removeItem(at: file)
        let deleted = try await repo.partialStaging(path: path, unstage: false)
        let first = deleted.hunks.flatMap(\.lines).first { $0.text == "-first" }!
        try await repo.applyPartialStaging(deleted, selectedLines: [first.id])
        state = try await repo.fileComparison(path: path); XCTAssertEqual(state.index.text, "second\nthird\n"); XCTAssertFalse(state.worktree.exists)
        try await repo.stage(paths: [path])
        let restore = try await repo.partialStaging(path: path, unstage: true)
        let restored = restore.hunks.flatMap(\.lines).first { $0.text == "+third" }!
        try await repo.applyPartialStaging(restore, selectedLines: [restored.id])
        state = try await repo.fileComparison(path: path); XCTAssertEqual(state.index.text, "third\n"); XCTAssertFalse(state.worktree.exists)
    }
    func testSelectedDeletionAdditionUnstageAndStaleSnapshot() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for args in [["init"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"]] { _ = try await GitProcess.run(at: dir, arguments: args) }
        let repo = GitRepository(url: dir), path = "space name.txt", file = dir.appendingPathComponent(path)
        try Data("a\nb\nc\n".utf8).write(to: file); try await repo.stage(paths: [path]); try await repo.commit(message: "base")
        try Data("a\nB\nc\nextra\n".utf8).write(to: file)
        let initial = try await repo.partialStaging(path: path, unstage: false)
        let deletion = initial.hunks.flatMap(\.lines).first { $0.text == "-b" }!
        try await repo.applyPartialStaging(initial, selectedLines: [deletion.id])
        var state = try await repo.fileComparison(path: path)
        XCTAssertEqual(state.index.text, "a\nc\n"); XCTAssertEqual(state.worktree.text, "a\nB\nc\nextra\n")
        do { try await repo.applyPartialStaging(initial, selectedLines: [deletion.id]); XCTFail("stale snapshot must fail") } catch { }
        let second = try await repo.partialStaging(path: path, unstage: false)
        let addition = second.hunks.flatMap(\.lines).first { $0.text == "+B" }!
        try await repo.applyPartialStaging(second, selectedLines: [addition.id])
        state = try await repo.fileComparison(path: path); XCTAssertEqual(state.index.text, "a\nB\nc\n")
        let undo = try await repo.partialStaging(path: path, unstage: true)
        try await repo.applyPartialStaging(undo, selectedLines: Set(undo.hunks.flatMap(\.lines).filter(\.isChange).map(\.id)))
        state = try await repo.fileComparison(path: path); XCTAssertEqual(state.index.text, "a\nb\nc\n"); XCTAssertEqual(state.worktree.text, "a\nB\nc\nextra\n")
        try Data("a\nb\nC".utf8).write(to: file)
        let noNewline = try await repo.partialStaging(path: path, unstage: false)
        try await repo.applyPartialStaging(noNewline, selectedLines: Set(noNewline.hunks.flatMap(\.lines).filter(\.isChange).map(\.id)))
        state = try await repo.fileComparison(path: path); XCTAssertEqual(state.index.text, "a\nb\nC")
        try await repo.saveIndex(path: path, text: "edited index\n", expected: state.index)
        state = try await repo.fileComparison(path: path); XCTAssertEqual(state.index.text, "edited index\n"); XCTAssertEqual(state.worktree.text, "a\nb\nC")
    }
}
