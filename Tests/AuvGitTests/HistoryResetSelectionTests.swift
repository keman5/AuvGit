import XCTest
@testable import AuvGit
@testable import GitCore

@MainActor
final class HistoryResetSelectionTests: XCTestCase {
    func testSelectedCommitResetMovesAllLaterChangesToUnstagedWorktree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        for (key, value) in [("user.name", "Reset Tester"), ("user.email", "reset@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] {
            _ = try await repo.workflowRead(["config", key, value])
        }
        let file = root.appendingPathComponent("file.txt")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file.txt"])
        try await repo.commit(message: "Selected commit")
        let target = try await repo.workflowRevision("HEAD")
        try "later\n".write(to: file, atomically: true, encoding: .utf8)
        try "added\n".write(to: root.appendingPathComponent("added.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file.txt", "added.txt"])
        try await repo.commit(message: "First later commit")
        try "tip\n".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file.txt"])
        try await repo.commit(message: "Second later commit")
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        await store.open(root)
        let tip = try await repo.workflowRevision("HEAD")
        store.selectedCommit = nil
        let initialFallback = try await store.historyResetRequest(advanced: true)
        XCTAssertEqual(initialFallback?.commit.hash, tip)
        store.selectedCommit = target

        // No window or history focus: the global command must still use selection.
        for advanced in [false, true] {
            let resolved = try await store.historyResetRequest(advanced: advanced)
            let request = try XCTUnwrap(resolved)
            XCTAssertEqual(request.commit.hash, target)
            XCTAssertEqual(request.repositoryURL, store.repositoryURL)
            XCTAssertEqual(request.advanced, advanced)
        }
        let resolved = try await store.historyResetRequest(advanced: true)
        let request = try XCTUnwrap(resolved)
        let activeRepo = try XCTUnwrap(store.repository)
        let context = try await activeRepo.resetContext()
        _ = try await activeRepo.reset(to: request.commit.hash, mode: .mixed, expected: context)
        let head = try await activeRepo.workflowRevision("HEAD")
        let index = try await activeRepo.workflowRead(["show", ":file.txt"])
        let staged = try await activeRepo.workflowRead(["diff", "--cached", "--name-only"])
        let files = try await activeRepo.status()
        XCTAssertEqual(head, target)
        XCTAssertEqual(index, "base\n")
        XCTAssertEqual(staged, "")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "tip\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("added.txt"), encoding: .utf8), "added\n")
        XCTAssertTrue(files.contains { $0.path == "file.txt" && $0.isUnstaged && !$0.isStaged })
        XCTAssertTrue(files.contains { $0.path == "added.txt" && $0.isUntracked })

        store.selectedCommit = nil
        let resolvedFallback = try await store.historyResetRequest(advanced: true)
        let fallback = try XCTUnwrap(resolvedFallback)
        XCTAssertEqual(fallback.commit.hash, target)
        store.isBusy = true
        let busyRequest = try await store.historyResetRequest(advanced: true)
        XCTAssertNil(busyRequest)
    }
}
