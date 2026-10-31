import XCTest
@testable import AuvGit
@testable import GitCore

final class RepositoryEventScopeTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/auvgit-event-scope")
    private func scope(_ paths: [String], directories: Set<String> = [], dropped: Bool = false) -> (full: Bool, worktree: [String]) {
        RepositoryEventScope.classify(.init(paths: Set(paths), directories: directories, requiresRescan: dropped), root: root, metadata: [root.path + "/.git", "/tmp/auvgit-external-metadata"])
    }
    func testGitObjectLogAndLockWritesDoNotRefresh() {
        let result = scope(["objects/ab/hash", "logs/HEAD", "index.lock", "refs/heads/main.lock", "FETCH_HEAD", "COMMIT_EDITMSG"].map { root.path + "/.git/" + $0 })
        XCTAssertFalse(result.full)
        XCTAssertTrue(result.worktree.isEmpty)
    }
    func testSemanticMetadataAndExternalGitDirectoryRequireFullRefresh() {
        for path in ["HEAD", "index", "config", "refs/heads/main", "packed-refs", "MERGE_HEAD", "logs/refs/stash"] {
            XCTAssertTrue(scope([root.path + "/.git/" + path]).full, path)
        }
        XCTAssertTrue(scope(["/tmp/auvgit-external-metadata/refs/heads/main"]).full)
        XCTAssertFalse(scope(["/tmp/auvgit-external-metadata/objects/ab/hash"]).full)
    }
    func testDroppedDirectoryAndUnknownEventsFallBackToFullRefresh() {
        XCTAssertTrue(scope([], dropped: true).full)
        let directory = root.path + "/Sources"
        XCTAssertTrue(scope([directory], directories: [directory]).full)
        XCTAssertTrue(scope(["/tmp/unrelated/file"]).full)
        XCTAssertTrue(scope([root.path + "-sibling/file"]).full)
        XCTAssertTrue(scope([root.path]).full)
    }
    func testWorktreeEventsAreUniqueSortedRelativePaths() {
        let result = scope([root.path + "/z.txt", root.path + "/Sources/a.swift", root.path + "/z.txt", root.path + "/.git/objects/ab/hash"])
        XCTAssertFalse(result.full)
        XCTAssertEqual(result.worktree, ["Sources/a.swift", "z.txt"])
    }
    func testIgnoreMatchingKeepsTrackedFilesInsideIgnoredParents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await GitProcess.run(at: directory, arguments: ["init", "-b", "main"])
        try "generated/\n*.log\n".write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("generated"), withIntermediateDirectories: true)
        try "tracked".write(to: directory.appendingPathComponent("generated/tracked.log"), atomically: true, encoding: .utf8)
        _ = try await GitProcess.run(at: directory, arguments: ["add", "-f", "generated/tracked.log"])
        let repository = GitRepository(url: directory)
        let ignored = try await repository.relevantWorktreeEvents(["generated/cache.bin", "activity.log"])
        XCTAssertFalse(ignored)
        let tracked = try await repository.relevantWorktreeEvents(["generated/tracked.log"])
        XCTAssertTrue(tracked)
        let mixed = try await repository.relevantWorktreeEvents(["generated/cache.bin", "source.swift"])
        XCTAssertTrue(mixed)
        let empty = try await repository.relevantWorktreeEvents([])
        XCTAssertFalse(empty)
    }
}
