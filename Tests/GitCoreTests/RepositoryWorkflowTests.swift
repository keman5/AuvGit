import XCTest
@testable import GitCore
final class RepositoryWorkflowTests: XCTestCase {
    func testReferenceCompareBlamePartialStashAndReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        _ = try await repo.workflowRead(["config", "user.name", "Tester"])
        _ = try await repo.workflowRead(["config", "user.email", "test@example.invalid"])
        try "first\n".write(to: root.appendingPathComponent("a file"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["a file"]); try await repo.commit(message: "first")
        try "second\n".write(to: root.appendingPathComponent("a file"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["a file"]); try await repo.commit(message: "second")
        let diff = try await repo.compareReferences("HEAD~1", "HEAD"); XCTAssertTrue(diff.contains("+second"))
        let blame = try await repo.blameText(path: "a file", revision: "HEAD"); XCTAssertTrue(blame.contains("Tester"))
        try "third\n".write(to: root.appendingPathComponent("a file"), atomically: true, encoding: .utf8)
        try "keep\n".write(to: root.appendingPathComponent("other"), atomically: true, encoding: .utf8)
        _ = try await repo.advancedOperation(.partialStash, first: "a file", second: "partial")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a file"), encoding: .utf8), "second\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("other").path))
        _ = try await repo.advancedOperation(.resetSoft, first: "HEAD~1", second: "")
        let status = try await repo.status(); XCTAssertTrue(status.contains { $0.path == "a file" && $0.isStaged })
        do { _ = try await repo.compareReferences("--all", "HEAD"); XCTFail("Option revision accepted") } catch { }
        do { _ = try await repo.blameText(path: "../outside", revision: "HEAD"); XCTFail("Traversal accepted") } catch { }
    }
    func testCloneAndRemotePreviewWithLocalBareRepository() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let bare = parent.appendingPathComponent("remote.git")
        _ = try await GitProcess.run(at: parent, arguments: ["init", "--bare", bare.path])
        let repo = try await GitRepository.clone(source: bare.path, destination: parent.appendingPathComponent("clone"))
        let remotes = try await repo.advancedOperation(.remoteList, first: "", second: "")
        XCTAssertTrue(remotes.contains("origin"))
        _ = try await repo.advancedOperation(.remoteAdd, first: "second", second: bare.path)
        _ = try await repo.advancedOperation(.remoteRemove, first: "second", second: "")
        let after = try await repo.advancedOperation(.remoteList, first: "", second: "")
        XCTAssertFalse(after.contains("second"))
    }
}
