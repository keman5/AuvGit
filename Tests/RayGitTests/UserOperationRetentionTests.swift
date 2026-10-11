import XCTest
import Combine
@testable import GitCore
@testable import RayGit

@MainActor
final class UserOperationRetentionTests: XCTestCase {
    func testRoutineCommandRecordsDoNotInvalidateWorkspaceAndStillUpdateLog() async throws {
        let store = RepositoryStore(persistsSession: false)
        let repository = GitRepository(url: URL(fileURLWithPath: "/tmp/log-isolation"))
        store.repository = repository; store.repositoryURL = repository.url
        var workspaceUpdates = 0, logUpdates = 0
        let workspace = store.objectWillChange.sink { workspaceUpdates += 1 }
        let log = store.commandRecords.objectWillChange.sink { logUpdates += 1 }
        defer { workspace.cancel(); log.cancel() }
        for _ in 0..<20 {
            GitCommandLog.record(directory: repository.url, executable: "git", arguments: ["status"], output: "", error: nil, exitCode: 0, started: Date())
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(workspaceUpdates, 0)
        XCTAssertEqual(logUpdates, 20)
        XCTAssertEqual(store.operationLog.count, 20)
    }
    func testLatestActionSurvivesRefreshAndReadCommandChurn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitProcess.run(at: root, arguments: ["init", "-b", "main"])
        let store = RepositoryStore(persistsSession: false)
        await store.open(root)
        let repository = try XCTUnwrap(store.repository)
        store.beginUserOperation("Pull")
        try await GitCommandLog.$operationID.withValue(store.currentUserOperationID) { try await GitCommandLog.$userInitiated.withValue(true) {
            _ = try await GitProcess.run(at: root, arguments: ["status", "--porcelain"])
        }
        }
        store.completeNetworkOperation("Pull", repository: repository)
        let status = store.status
        for _ in 0..<310 { _ = try await GitProcess.run(at: root, arguments: ["rev-parse", "--git-dir"]) }
        await store.refresh()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.status, status)
        XCTAssertEqual(store.operationLog.first?.operation, "Pull")
        XCTAssertTrue(store.operationLog.contains { $0.userInitiated && !$0.command.isEmpty })
        let summary = try XCTUnwrap(store.operationLog.first)
        XCTAssertEqual(store.commands(for: summary).count, 1)
        XCTAssertTrue(store.commands(for: summary)[0].command.contains("status"))
        store.beginUserOperation("Push")
        store.completeNetworkOperation("Push", repository: repository)
        XCTAssertTrue(store.commands(for: store.operationLog.first!).isEmpty)
    }
    func testAssociatedCommandDetailsRedactSecretsAndStayIsolated() async throws {
        let store = RepositoryStore(persistsSession: false)
        let repository = GitRepository(url: URL(fileURLWithPath: "/tmp/user-operation"))
        store.repository = repository; store.repositoryURL = repository.url
        store.beginUserOperation("Pull")
        GitCommandLog.$operationID.withValue(store.currentUserOperationID) {
            GitCommandLog.$userInitiated.withValue(true) {
                GitCommandLog.record(directory: repository.url, executable: "git", arguments: ["pull"], output: "token=private-secret", error: nil, exitCode: 0, started: Date())
            }
        }
        store.completeNetworkOperation("Pull", repository: repository)
        let summary = try XCTUnwrap(store.operationLog.first)
        try await Task.sleep(nanoseconds: 50_000_000)
        let commands = store.commands(for: summary)
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands[0].command.contains("pull"))
        XCTAssertFalse(commands[0].output.contains("private-secret"))
        store.beginUserOperation("Push")
        store.completeNetworkOperation("Push", repository: repository)
        XCTAssertTrue(store.commands(for: store.operationLog.first!).isEmpty)
        XCTAssertEqual(store.commands(for: summary).count, 1)
    }
    func testFailureAndCancellationKeepTheirOutcomeAndRedactSecrets() {
        let store = RepositoryStore(persistsSession: false)
        let repository = GitRepository(url: URL(fileURLWithPath: "/tmp/user-operation"))
        store.repository = repository; store.repositoryURL = repository.url
        store.beginUserOperation("Push")
        store.finishUserOperation("Push", repository: repository, failure: GitError("token=private-secret"))
        XCTAssertFalse(store.operationLog.first!.error!.contains("private-secret"))
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.displayStatus.contains(store.status))
        store.beginUserOperation("Pull")
        store.finishUserOperation("Pull", repository: repository, failure: CancellationError())
        XCTAssertTrue(store.operationLog.first!.cancelled)
        XCTAssertNil(store.error)
    }
}
