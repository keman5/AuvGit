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

        _ = try await GitProcess.run(at: root, arguments: ["init", "--bare", remote.path])
        _ = try await GitProcess.run(at: local, arguments: ["remote", "add", "origin", remote.path])
        _ = try await GitProcess.run(at: local, arguments: ["push", "-u", "origin", "main"])
        let synchronized = try await repository.localUnpushedCommitHashes(limit: 100)
        XCTAssertEqual(synchronized, [])

        _ = try await GitProcess.run(at: local, arguments: ["commit", "--allow-empty", "-m", "local"])
        let head = try await repository.workflowRevision("HEAD")
        let unpushed = try await repository.localUnpushedCommitHashes(limit: 100)
        XCTAssertEqual(unpushed, [head])
    }
}
