import XCTest
@testable import GitCore
@testable import RayGit

final class StashHistoryTests: XCTestCase {
    func testPinnedStashIncludesTrackedAndUntrackedFilesAfterAnotherStashIsCreated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("raygit-stash-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = GitRepository(url: root)
        for args in [["init", "-b", "main"], ["config", "user.name", "Fixture"], ["config", "user.email", "fixture@example.invalid"], ["config", "commit.gpgsign", "false"], ["config", "core.hooksPath", root.appendingPathComponent("no-hooks").path]] {
            _ = try await GitProcess.run(at: root, arguments: args)
        }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try await repository.stage(paths: ["tracked.txt"]); try await repository.commit(message: "Base")
        try Data("first tracked stash\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try Data("first untracked stash\n".utf8).write(to: root.appendingPathComponent("new file.txt"))
        _ = try await GitProcess.run(at: root, arguments: ["stash", "push", "-u", "-m", "first"])
        let firstHash = try await repository.workflowRevision("stash@{0}")
        try Data("second stash\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        _ = try await GitProcess.run(at: root, arguments: ["stash", "push", "-m", "second"])
        let files = try await StashHistory.files(repository: repository, hash: firstHash)
        XCTAssertEqual(Set(files.files.map(\.path)), ["tracked.txt", "new file.txt"])
        XCTAssertEqual(files.untracked, ["new file.txt"])
        let tracked = try await StashHistory.diff(repository: repository, hash: firstHash, path: "tracked.txt", untracked: false)
        let untracked = try await StashHistory.diff(repository: repository, hash: firstHash, path: "new file.txt", untracked: true)
        XCTAssertTrue(tracked.contains("+first tracked stash")); XCTAssertFalse(tracked.contains("+second stash"))
        XCTAssertTrue(untracked.contains("+first untracked stash"))
    }
}
