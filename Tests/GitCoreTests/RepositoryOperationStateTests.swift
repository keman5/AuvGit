import XCTest
@testable import GitCore

final class RepositoryOperationStateTests: XCTestCase {
    func testMergeAndBothRebaseBackendsDetectAndAbortToOriginalHead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        for (key, value) in [("user.name", "Test"), ("user.email", "test@example.invalid"), ("commit.gpgsign", "false")] {
            _ = try await repo.workflowRead(["config", key, value])
        }
        let file = root.appendingPathComponent("file")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file"])
        try await repo.commit(message: "Base")
        _ = try await repo.workflowRead(["switch", "-c", "side"])
        try "side\n".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file"])
        try await repo.commit(message: "Side")
        _ = try await repo.workflowRead(["switch", "-c", "original", "HEAD~1"])
        try "original\n".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file"])
        try await repo.commit(message: "Original")
        let original = try await repo.workflowRevision("HEAD")
        for (arguments, operation, abort) in [
            (["merge", "side"], RepositoryOperationState.merge, RepositoryWorkflow.mergeAbort),
            (["rebase", "side"], .rebase, .rebaseAbort),
            (["rebase", "--apply", "side"], .rebase, .rebaseAbort)
        ] {
            _ = try await GitProcess.run(at: root, arguments: arguments, allowedCodes: [1])
            let state = try await repo.changeState(files: repo.status())
            XCTAssertEqual(state.operation, operation)
            _ = try await repo.advancedOperation(abort, first: "", second: "")
            let restored = try await repo.operationState(), head = try await repo.workflowRevision("HEAD")
            XCTAssertNil(restored)
            XCTAssertEqual(head, original)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original\n")
        }
    }

    func testMarkersChangeSnapshotAndLinkedWorktreeUsesItsOwnGitDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let linked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: linked); try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        for (key, value) in [("user.name", "Test"), ("user.email", "test@example.invalid"), ("commit.gpgsign", "false")] {
            _ = try await repo.workflowRead(["config", key, value])
        }
        _ = try await repo.workflowRead(["commit", "--allow-empty", "-m", "Base"])
        _ = try await repo.workflowRead(["worktree", "add", "-b", "linked", linked.path])
        let worktree = GitRepository(url: linked)
        let gitPath = try await worktree.workflowRead(["rev-parse", "--absolute-git-dir"]).trimmingCharacters(in: .newlines)
        let directory = URL(fileURLWithPath: gitPath)
        let clean = try await worktree.changeState(files: [])
        let marker = directory.appendingPathComponent("MERGE_HEAD")
        try "marker".write(to: marker, atomically: true, encoding: .utf8)
        let merging = try await worktree.changeState(files: [])
        XCTAssertEqual(merging.operation, .merge)
        XCTAssertNotEqual(clean, merging)
        let mainState = try await repo.operationState()
        XCTAssertNil(mainState)
        try FileManager.default.removeItem(at: marker)
        let apply = directory.appendingPathComponent("rebase-apply")
        try FileManager.default.createDirectory(at: apply, withIntermediateDirectories: true)
        let amState = try await worktree.operationState()
        XCTAssertNil(amState, "git am also uses rebase-apply; require the rebasing marker")
        try "".write(to: apply.appendingPathComponent("rebasing"), atomically: true, encoding: .utf8)
        let rebaseState = try await worktree.operationState()
        XCTAssertEqual(rebaseState, .rebase)
        let legacy = try JSONEncoder().encode(clean)
        XCTAssertEqual(try JSONDecoder().decode(RepositoryChangeState.self, from: legacy), clean)
    }
}
