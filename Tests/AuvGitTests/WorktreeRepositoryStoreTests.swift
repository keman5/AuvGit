import XCTest
@testable import AuvGit
@testable import GitCore

@MainActor
final class WorktreeRepositoryStoreTests: XCTestCase {
    func testOpeningRepositoryRegistersUsableLinkedWorktreesWithoutChangingSelection() async throws {
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
        let store = RepositoryStore(persistsSession: false)
        store.openRepositories = []
        store.recentPaths = []
        defer { store.closeTransientSession() }

        await store.open(main)

        XCTAssertTrue(try XCTUnwrap(store.repositoryURL).path.hasSuffix("/main repository"))
        XCTAssertEqual(store.openRepositories.count, 2)
        XCTAssertEqual(store.recentPaths.count, 2)
        for expected in [main, linked] {
            XCTAssertTrue(store.openRepositories.contains { RepositoryStore.sameRepositoryLocation(URL(fileURLWithPath: $0), expected) })
            XCTAssertTrue(store.recentPaths.contains { RepositoryStore.sameRepositoryLocation(URL(fileURLWithPath: $0), expected) })
        }
    }
}
