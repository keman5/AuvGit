import XCTest
@testable import GitCore

final class ConflictRecoveryTests: XCTestCase {
    private func fixture() async throws -> GitRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("conflict-recovery-" + UUID().uuidString)
        let repo = try await GitRepository.initialize(at: root)
        for (key, value) in [("user.name", "Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false")] {
            _ = try await repo.workflowRead(["config", key, value])
        }
        for name in ["conflict", "deleted", "normal"] { try "base\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try "ignored\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["conflict", "deleted", "normal", ".gitignore"])
        try await repo.commit(message: "Base")
        for name in ["conflict", "deleted"] { try "stashed\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        _ = try await repo.workflowRead(["stash", "push", "-m", "Fixture changes"])
        try "HEAD version\n".write(to: root.appendingPathComponent("conflict"), atomically: true, encoding: .utf8)
        _ = try await repo.workflowRead(["rm", "--", "deleted"])
        try await repo.stage(paths: ["conflict"]); try await repo.commit(message: "Divergent changes")
        do { _ = try await repo.workflowRead(["stash", "apply"]); XCTFail("Fixture should conflict") } catch { }
        let status = try await repo.status()
        XCTAssertEqual(Set(status.filter(\.isConflict).map(\.path)), ["conflict", "deleted"])
        _ = try await repo.resetContext() // A failed stash apply has no active merge/rebase marker.
        return repo
    }

    func testDiscardOrphanedConflictsRestoresHEADAndPreservesOrdinaryIndex() async throws {
        let repo = try await fixture(), root = repo.url
        defer { try? FileManager.default.removeItem(at: root) }
        try "staged\n".write(to: root.appendingPathComponent("normal"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["normal"])
        try "worktree\n".write(to: root.appendingPathComponent("normal"), atomically: true, encoding: .utf8)
        for name in ["new", "keep-new", "ignored"] { try name.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let before = try await repo.workflowRead(["ls-files", "-u"]), head = try await repo.workflowRevision("HEAD")
        do { try await repo.discardWorkspace(paths: ["conflict", "deleted", "normal", "new", "missing"]); XCTFail("Validate the whole batch") } catch { }
        let afterInvalid = try await repo.workflowRead(["ls-files", "-u"])
        XCTAssertEqual(afterInvalid, before)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("normal"), encoding: .utf8), "worktree\n")
        try await repo.discardWorkspace(paths: ["conflict", "deleted", "normal", "new"])
        let unmerged = try await repo.workflowRead(["ls-files", "-u"]), afterHead = try await repo.workflowRevision("HEAD")
        let normalIndex = try await repo.workflowRead(["show", ":normal"])
        XCTAssertTrue(unmerged.isEmpty); XCTAssertEqual(afterHead, head); XCTAssertEqual(normalIndex, "staged\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("normal"), encoding: .utf8), "staged\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("conflict"), encoding: .utf8), "HEAD version\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("deleted").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("keep-new").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("ignored").path))
    }

    func testHardResetAcceptsUnmergedIndexWithoutActiveOperation() async throws {
        let repo = try await fixture()
        defer { try? FileManager.default.removeItem(at: repo.url) }
        let context = try await repo.resetContext()
        _ = try await repo.reset(to: context.head, mode: .hard, expected: context)
        let status = try await repo.status()
        XCTAssertTrue(status.isEmpty)
    }

    func testDiscardRejectsActiveOperationBeforeChangingAnyPath() async throws {
        let repo = try await fixture(), root = repo.url
        defer { try? FileManager.default.removeItem(at: root) }
        try "worktree\n".write(to: root.appendingPathComponent("normal"), atomically: true, encoding: .utf8)
        try "new".write(to: root.appendingPathComponent("new"), atomically: true, encoding: .utf8)
        let head = try await repo.workflowRevision("HEAD"), before = try await repo.workflowRead(["ls-files", "-u"])
        for marker in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer"] {
            let path = try await repo.workflowRead(["rev-parse", "--git-path", marker]).trimmingCharacters(in: .newlines)
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
            try head.write(to: url, atomically: true, encoding: .utf8)
            do { try await repo.discardWorkspace(paths: ["conflict", "normal", "new"]); XCTFail("Active \(marker) accepted") } catch { }
            let after = try await repo.workflowRead(["ls-files", "-u"])
            XCTAssertEqual(after, before)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("normal"), encoding: .utf8), "worktree\n")
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
            try FileManager.default.removeItem(at: url)
        }
    }
}
