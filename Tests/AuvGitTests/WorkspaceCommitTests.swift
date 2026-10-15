import XCTest
import GitCore
@testable import AuvGit

@MainActor
final class WorkspaceCommitTests: XCTestCase {
    func testAmendWithoutStagedFilesIncludesAllWorkspaceChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        for (key, value) in [("user.name", "Test"), ("user.email", "test@example.test"), ("commit.gpgSign", "false")] {
            _ = try await repo.workflowRead(["config", key, value])
        }
        func write(_ path: String, _ value: String) throws { try Data(value.utf8).write(to: root.appendingPathComponent(path)) }
        try write("tracked.txt", "base"); try write("deleted.txt", "base"); try write(".gitignore", "ignored.txt\n")
        try await repo.stage(paths: ["tracked.txt", "deleted.txt", ".gitignore"])
        try await repo.commit(message: "Base")
        try write("tracked.txt", "amended"); try write("new.txt", "new"); try write("ignored.txt", "private")
        try FileManager.default.removeItem(at: root.appendingPathComponent("deleted.txt"))
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        store.repository = repo; store.repositoryURL = repo.url
        store.files = try await repo.status(); store.commitMessage = "Amend workspace"; store.amend = true
        store.commit(); try await waitForCommit(store)
        XCTAssertNil(store.workspaceCommitRequest)
        let content = try await repo.workflowRead(["show", "HEAD:tracked.txt"])
        let tree = try await repo.workflowRead(["ls-tree", "-r", "--name-only", "HEAD"])
        let count = try await repo.workflowRead(["rev-list", "--count", "HEAD"])
        XCTAssertEqual(content, "amended")
        XCTAssertTrue(tree.contains("new.txt")); XCTAssertFalse(tree.contains("deleted.txt")); XCTAssertFalse(tree.contains("ignored.txt"))
        XCTAssertEqual(count.trimmingCharacters(in: .whitespacesAndNewlines), "1")
        let cleanStatus = try await repo.status()
        XCTAssertTrue(cleanStatus.isEmpty)
        store.files = []; store.commitMessage = "Message only"; store.amend = true
        store.commit(); try await waitForCommit(store)
        let message = try await repo.workflowRead(["log", "-1", "--format=%s"])
        XCTAssertEqual(message.trimmingCharacters(in: .whitespacesAndNewlines), "Message only")
    }
    func testAmendWithStagedFilesPreservesUnstagedAndUntrackedChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        for (key, value) in [("user.name", "Test"), ("user.email", "test@example.test"), ("commit.gpgSign", "false")] {
            _ = try await repo.workflowRead(["config", key, value])
        }
        let file = root.appendingPathComponent("tracked.txt")
        try Data("base".utf8).write(to: file); try await repo.stage(paths: ["tracked.txt"]); try await repo.commit(message: "Base")
        try Data("staged".utf8).write(to: file); try await repo.stage(paths: ["tracked.txt"])
        try Data("unstaged".utf8).write(to: file); try Data("new".utf8).write(to: root.appendingPathComponent("new.txt"))
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        store.repository = repo; store.repositoryURL = repo.url
        store.files = try await repo.status(); store.commitMessage = "Staged amendment"; store.amend = true
        store.commit(); try await waitForCommit(store)
        let content = try await repo.workflowRead(["show", "HEAD:tracked.txt"])
        let status = try await repo.status()
        XCTAssertEqual(content, "staged")
        XCTAssertTrue(status.contains { $0.path == "tracked.txt" && $0.isUnstaged })
        XCTAssertTrue(status.contains { $0.path == "new.txt" && $0.isUntracked })
    }
    private func waitForCommit(_ store: RepositoryStore) async throws {
        for _ in 0..<1000 where store.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isBusy)
        XCTAssertNil(store.error)
    }

    func testUnstagedCommitChoiceAndStagedOnlyBehavior() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        for (key, value) in [("user.name", "Test"), ("user.email", "test@example.test"), ("commit.gpgSign", "false")] {
            _ = try await repo.workflowRead(["config", key, value])
        }
        func write(_ path: String, _ value: String) throws { try Data(value.utf8).write(to: root.appendingPathComponent(path)) }
        try write("tracked.txt", "base"); try write("deleted.txt", "base"); try write(".gitignore", "ignored.txt\n")
        try await repo.stage(paths: ["tracked.txt", "deleted.txt", ".gitignore"])
        try await repo.commit(message: "Base")
        try write("tracked.txt", "changed"); try write("new.txt", "new"); try write("ignored.txt", "private")
        try FileManager.default.removeItem(at: root.appendingPathComponent("deleted.txt"))
        let store = RepositoryStore(persistsSession: false)
        store.repository = repo; store.repositoryURL = repo.url
        store.files = try await repo.status(); store.commitMessage = "Tracked changes"
        XCTAssertTrue(store.canCommit)
        let before = try await repo.workflowRevision("HEAD")
        store.commit(); try await waitForCommit(store)
        let request = try XCTUnwrap(store.workspaceCommitRequest)
        let unchanged = try await repo.workflowRevision("HEAD")
        XCTAssertEqual(before, unchanged)
        let index = try await repo.workflowRead(["diff", "--cached", "--name-only"])
        XCTAssertTrue(index.isEmpty, "The question must not stage files")
        store.workspaceCommitRequest = nil // Cancel leaves the draft and repository unchanged.
        XCTAssertEqual(store.commitMessage, "Tracked changes")
        store.confirmWorkspaceCommit(request, includeUntracked: false); try await waitForCommit(store)
        let tracked = try await repo.workflowRead(["show", "HEAD:tracked.txt"])
        XCTAssertEqual(tracked, "changed")
        let tree = try await repo.workflowRead(["ls-tree", "-r", "--name-only", "HEAD"])
        XCTAssertFalse(tree.contains("new.txt")); XCTAssertFalse(tree.contains("deleted.txt")); XCTAssertFalse(tree.contains("ignored.txt"))

        store.files = try await repo.status(); store.commitMessage = "New file"
        store.commit(); try await waitForCommit(store)
        let untrackedRequest = try XCTUnwrap(store.workspaceCommitRequest)
        XCTAssertFalse(untrackedRequest.hasTrackedChanges)
        store.confirmWorkspaceCommit(untrackedRequest, includeUntracked: true); try await waitForCommit(store)
        let added = try await repo.workflowRead(["show", "HEAD:new.txt"])
        XCTAssertEqual(added, "new")

        try write("tracked.txt", "staged"); try await repo.stage(paths: ["tracked.txt"])
        try write("tracked.txt", "later unstaged"); try write("another.txt", "untracked")
        store.files = try await repo.status(); store.commitMessage = "Staged only"
        store.commit(); try await waitForCommit(store)
        XCTAssertNil(store.workspaceCommitRequest)
        let committed = try await repo.workflowRead(["show", "HEAD:tracked.txt"])
        XCTAssertEqual(committed, "staged")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("tracked.txt")), "later unstaged")
        let remaining = try await repo.status()
        XCTAssertTrue(remaining.contains { $0.path == "another.txt" && $0.isUntracked })
        try FileManager.default.removeItem(at: root.appendingPathComponent("another.txt"))
        store.files = try await repo.status(); store.commitMessage = "Tracked without staging"
        store.commit(); try await waitForCommit(store)
        XCTAssertNil(store.workspaceCommitRequest)
        let automatic = try await repo.workflowRead(["show", "HEAD:tracked.txt"])
        XCTAssertEqual(automatic, "later unstaged")
        store.files = []; store.commitMessage = "No changes"
        XCTAssertFalse(store.canCommit)
        store.files = [GitFile(path: "conflict", indexStatus: "U", worktreeStatus: "U")]
        XCTAssertFalse(store.canCommit)
    }
}
