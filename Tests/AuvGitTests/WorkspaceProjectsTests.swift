import XCTest
@testable import AuvGit
@testable import GitCore

@MainActor
final class WorkspaceProjectsTests: XCTestCase {
    func testSwitchingDuringGitOperationRetainsOwnerAndAllowsOtherProjectWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        for url in [first, second] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            _ = try await GitProcess.run(at: url, arguments: ["init", "-b", "main"])
        }
        let original = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        let projects = WorkspaceProjects(initial: original)
        defer { for store in projects.sessions { store.closeTransientSession() } }
        await original.open(first)
        original.commitMessage = "first draft"
        var release: CheckedContinuation<Void, Never>?
        var completedAt: URL?
        original.operation("Background fixture") { repository in
            await withCheckedContinuation { release = $0 }
            _ = try await repository.workflowRead(["status", "--porcelain"])
            completedAt = repository.url
        }
        let deadline = Date().addingTimeInterval(5)
        while release == nil, Date() < deadline { await Task.yield() }
        XCTAssertNotNil(release)
        XCTAssertTrue(original.isBusy)
        await original.open(second)
        let other = projects.active
        XCTAssertFalse(other === original)
        XCTAssertEqual(other.repositoryURL?.path, second.path)
        XCTAssertFalse(other.isBusy)
        XCTAssertTrue(original.isBusy)
        XCTAssertEqual(original.repositoryURL?.path, first.path)
        other.commitMessage = "second draft"
        var secondCompleted = false
        other.operation("Second fixture") { repository in
            XCTAssertEqual(repository.url.path, second.path)
            _ = try await repository.workflowRead(["status", "--porcelain"])
            secondCompleted = true
        }
        while other.isBusy, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(secondCompleted)
        XCTAssertTrue(original.isBusy)
        // Returning to an in-flight session does not replace or refresh its owner.
        await other.open(first)
        XCTAssertTrue(projects.active === original)
        XCTAssertTrue(original.isBusy)
        await original.open(second)
        XCTAssertTrue(projects.active === other)
        release?.resume()
        while original.isBusy, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(original.isBusy)
        XCTAssertEqual(completedAt?.path, first.path)
        XCTAssertTrue(projects.active === other)
        XCTAssertEqual(original.commitMessage, "first draft")
        XCTAssertEqual(other.commitMessage, "second draft")
        XCTAssertEqual(original.operationLog.first?.operation, "Background fixture")
        XCTAssertEqual(other.operationLog.first?.operation, "Second fixture")
    }
}
