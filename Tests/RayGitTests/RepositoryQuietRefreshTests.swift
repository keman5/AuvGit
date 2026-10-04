import XCTest
import Combine
@testable import RayGit
@testable import GitCore

@MainActor
final class RepositoryQuietRefreshTests: XCTestCase {
    func testSelectingSameRepositoryKeepsHistoryAndRefreshesChangedTextWithoutBusyFade() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let alias = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: alias); try? FileManager.default.removeItem(at: root) }
        _ = try await GitProcess.run(at: root, arguments: ["init"])
        _ = try await GitProcess.run(at: root, arguments: ["config", "user.name", "Test"])
        _ = try await GitProcess.run(at: root, arguments: ["config", "user.email", "test@example.com"])
        let file = root.appendingPathComponent("file.txt")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await GitProcess.run(at: root, arguments: ["add", "file.txt"])
        _ = try await GitProcess.run(at: root, arguments: ["commit", "-m", "Fixture"])
        try "first change\n".write(to: file, atomically: true, encoding: .utf8)
        let store = RepositoryStore(persistsSession: false)
        await store.open(root)
        store.mode = "workspace"; store.selectedPaths = ["file.txt"]
        await store.loadDiff()
        let commits = store.commits, generation = store.filesGeneration
        store.historySearch = "keep this filter"
        var busyTransitions: [Bool] = []
        let observation = store.$isBusy.dropFirst().sink { busyTransitions.append($0) }
        defer { observation.cancel() }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        try "second content with same M status\n".write(to: file, atomically: true, encoding: .utf8)
        await store.open(alias)
        XCTAssertEqual(store.commits, commits)
        XCTAssertEqual(store.historySearch, "keep this filter")
        XCTAssertEqual(store.filesGeneration, generation)
        XCTAssertTrue(store.diffText.contains("second content with same M status"))
        XCTAssertTrue(busyTransitions.isEmpty)
        XCTAssertTrue(RepositoryStore.sameRepositoryLocation(root, alias))
    }
}
