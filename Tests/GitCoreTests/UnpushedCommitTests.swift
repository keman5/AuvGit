import XCTest
@testable import GitCore

final class UnpushedCommitTests: XCTestCase {
    func testReportsNilWithoutUpstreamAndExactLocalRangeWithUpstream() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let local = root.appendingPathComponent("local")
        let remote = root.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"]] {
            _ = try await GitProcess.run(at: local, arguments: args)
        }
        let repository = GitRepository(url: local)
        _ = try await GitProcess.run(at: local, arguments: ["commit", "--allow-empty", "-m", "base"])
        let withoutUpstream = try await repository.localUnpushedCommitHashes(limit: 100)
        XCTAssertNil(withoutUpstream)
        let initial = try await repository.log()
        let unpublishedWithoutUpstream = try await repository.unpublishedCommitHashes(in: initial)
        XCTAssertEqual(unpublishedWithoutUpstream, Set(initial.map(\.hash)))

        _ = try await GitProcess.run(at: root, arguments: ["init", "--bare", remote.path])
        _ = try await GitProcess.run(at: local, arguments: ["remote", "add", "origin", remote.path])
        _ = try await GitProcess.run(at: local, arguments: ["push", "-u", "origin", "main"])
        let synchronized = try await repository.localUnpushedCommitHashes(limit: 100)
        XCTAssertEqual(synchronized, [])
        let published = try await repository.unpublishedCommitHashes(in: initial)
        XCTAssertEqual(published, [])
        _ = try await GitProcess.run(at: local, arguments: ["branch", "feature/work"])

        _ = try await GitProcess.run(at: local, arguments: ["commit", "--allow-empty", "-m", "local"])
        let head = try await repository.workflowRevision("HEAD")
        let unpushed = try await repository.localUnpushedCommitHashes(limit: 100)
        XCTAssertEqual(unpushed, [head])
        _ = try await GitProcess.run(at: local, arguments: ["checkout", "feature/work"])
        _ = try await GitProcess.run(at: local, arguments: ["commit", "--allow-empty", "-m", "side"])
        let side = try await repository.workflowRevision("HEAD")
        _ = try await GitProcess.run(at: local, arguments: ["checkout", "main"])
        let allCommits = try await repository.log()
        let unpublishedBranches = try await repository.unpublishedCommitHashes(in: allCommits)
        XCTAssertEqual(unpublishedBranches, [head, side])
        let filtered = try await repository.log(search: "side")
        let filteredUnpublished = try await repository.unpublishedCommitHashes(in: filtered)
        XCTAssertEqual(filteredUnpublished, [side], "A filtered graph must not depend on the remote label being visible")
        _ = try await GitProcess.run(at: local, arguments: ["push", "origin", "feature/work"])
        let afterSidePush = try await repository.unpublishedCommitHashes(in: allCommits)
        XCTAssertEqual(afterSidePush, [head])
        _ = try await GitProcess.run(at: local, arguments: ["push", "origin", "main"])
        let afterPush = try await repository.unpublishedCommitHashes(in: allCommits)
        XCTAssertEqual(afterPush, [])
    }
}
