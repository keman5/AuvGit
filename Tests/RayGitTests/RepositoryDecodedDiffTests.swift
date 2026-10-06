import XCTest
@testable import RayGit
@testable import GitCore

@MainActor
final class RepositoryDecodedDiffTests: XCTestCase {
    private func utf16(_ text: String) -> Data { Data([0xff, 0xfe]) + text.data(using: .utf16LittleEndian)! }
    func testMainWorkspaceStagedAndStashPreviewsDecodeTextWithoutChangingOriginalBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitProcess.run(at: root, arguments: ["init", "-b", "main"])
        _ = try await GitProcess.run(at: root, arguments: ["config", "user.name", "Test"])
        _ = try await GitProcess.run(at: root, arguments: ["config", "user.email", "test@example.com"])
        let file = root.appendingPathComponent("text.txt")
        let base = utf16("base version\n"), indexed = utf16("index version\n"), working = utf16("working version\n")
        try base.write(to: file)
        let repository = GitRepository(url: root)
        try await repository.stage(paths: ["text.txt"])
        try await repository.commit(message: "Fixture")
        try indexed.write(to: file)
        try await repository.stage(paths: ["text.txt"])
        try working.write(to: file)
        let raw = try await repository.diff(target: .worktree(path: "text.txt", untracked: false))
        XCTAssertTrue(DiffParser.parse(raw).isBinary)
        let store = RepositoryStore(persistsSession: false)
        await store.open(root)
        store.mode = "workspace"; store.selectedPaths = ["text.txt"]; store.stagedDiff = false
        await store.loadDiff()
        XCTAssertTrue(store.diffText.contains("-index version"))
        XCTAssertTrue(store.diffText.contains("+working version"))
        XCTAssertFalse(DiffParser.parse(store.diffText).isBinary)
        store.stagedDiff = true
        await store.loadDiff()
        XCTAssertTrue(store.diffText.contains("-base version"))
        XCTAssertTrue(store.diffText.contains("+index version"))
        XCTAssertFalse(store.diffText.contains("working version"))
        let stagedBytes = try await GitProcess.run(at: root, arguments: ["show", ":text.txt"]).data
        XCTAssertEqual(stagedBytes, indexed)
        XCTAssertEqual(try Data(contentsOf: file), working)

        try await repository.stash(message: "UTF16 fixture")
        let hash = try await repository.workflowRead(["rev-parse", "stash@{0}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        store.mode = "history"; store.historyStashHash = hash; store.selectedCommit = hash; store.selectedCommitPath = "text.txt"
        await store.loadDiff()
        XCTAssertTrue(store.diffText.contains("-base version"))
        XCTAssertTrue(store.diffText.contains("+working version"))
        XCTAssertFalse(DiffParser.parse(store.diffText).isBinary)
        XCTAssertEqual(try Data(contentsOf: file), base)
        let restoredIndex = try await GitProcess.run(at: root, arguments: ["show", ":text.txt"]).data
        XCTAssertEqual(restoredIndex, base)
    }
}
