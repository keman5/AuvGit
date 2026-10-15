import XCTest
@testable import GitCore
@testable import AuvGit

@MainActor
final class RepositoryContextTargetingTests: XCTestCase {
    func testContextOperationTargetsClickedRepositoryAndRetainsActiveRepository() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let active = root.appendingPathComponent("active"), clicked = root.appendingPathComponent("clicked")
        for directory in [active, clicked] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try await GitProcess.run(at: directory, arguments: ["init"])
        }
        let store = RepositoryStore(persistsSession: false)
        await store.open(active)
        let before = store.repository
        let success = await store.performRepositoryContextOperation("Edit Ignore File", path: clicked.path) { repository in
            try await repository.saveGitignore(text: "clicked-only\n", expected: nil)
        }
        XCTAssertTrue(success)
        XCTAssertTrue(store.repository === before)
        XCTAssertEqual(store.repositoryURL?.standardizedFileURL.path, active.standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.appendingPathComponent(".gitignore").path))
        XCTAssertEqual(try String(contentsOf: clicked.appendingPathComponent(".gitignore"), encoding: .utf8), "clicked-only\n")
        XCTAssertTrue(store.status.contains("clicked"))
        XCTAssertEqual(store.repositoryChangeCounts[clicked.path], 1)
    }
}
