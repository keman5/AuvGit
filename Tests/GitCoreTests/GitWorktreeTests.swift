import XCTest
@testable import GitCore

final class GitWorktreeTests: XCTestCase {
    func testParsesNulDelimitedPorcelainWithoutLosingState() throws {
        let data = Data("""
        worktree /tmp/main repository\0HEAD 1111111\0branch refs/heads/main\0\0worktree /tmp/topic\0HEAD 2222222\0branch refs/heads/feature/topic\0locked reason with spaces\0\0worktree /tmp/detached\0HEAD 3333333\0detached\0\0worktree /tmp/stale\0HEAD 4444444\0branch refs/heads/stale\0prunable gitdir file points to non-existent location\0\0
        """.utf8)

        let worktrees = GitWorktree.parsePorcelain(data)

        XCTAssertEqual(worktrees, [
            GitWorktree(path: "/tmp/main repository", head: "1111111", branch: "main"),
            GitWorktree(path: "/tmp/topic", head: "2222222", branch: "feature/topic", isLocked: true),
            GitWorktree(path: "/tmp/detached", head: "3333333", branch: nil),
            GitWorktree(path: "/tmp/stale", head: "4444444", branch: "stale", isPrunable: true),
        ])
    }

    func testDiscoversMainAndLinkedWorktreesWithLocalBranches() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let main = parent.appendingPathComponent("main repository")
        let linked = parent.appendingPathComponent("linked topic")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        for arguments in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"]] {
            _ = try await GitProcess.run(at: main, arguments: arguments)
        }
        try "base\n".write(to: main.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try await GitProcess.run(at: main, arguments: ["add", "file.txt"])
        _ = try await GitProcess.run(at: main, arguments: ["commit", "-m", "Fixture"])
        _ = try await GitProcess.run(at: main, arguments: ["worktree", "add", "-b", "feature/topic", linked.path])

        let worktrees = try await GitRepository(url: main).worktrees()
        let canonicalMain = try await GitRepository.open(main).url.path
        let canonicalLinked = try await GitRepository.open(linked).url.path

        let discoveredPaths = worktrees.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }
        let canonicalPaths = [canonicalMain, canonicalLinked].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        XCTAssertEqual(discoveredPaths, canonicalPaths)
        XCTAssertEqual(worktrees.map(\.branch), ["main", "feature/topic"])
        XCTAssertTrue(worktrees.allSatisfy { !$0.isPrunable && !$0.isBare })
    }
}
