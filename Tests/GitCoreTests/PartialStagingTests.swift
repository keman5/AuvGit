import XCTest
@testable import GitCore

final class PartialStagingTests: XCTestCase {
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
        try await repo.saveIndex(path: path, text: "edited index\n", expected: state.index)
        state = try await repo.fileComparison(path: path); XCTAssertEqual(state.index.text, "edited index\n"); XCTAssertEqual(state.worktree.text, "a\nB\nc\nextra\n")
    }
}
