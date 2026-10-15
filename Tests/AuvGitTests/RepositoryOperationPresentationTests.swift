import XCTest
import GitCore
@testable import AuvGit

@MainActor
final class RepositoryOperationPresentationTests: XCTestCase {
    func testFileRefreshTracksExternalOperationAndRepositorySwitchClearsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        let store = RepositoryStore(persistsSession: false)
        store.repository = repo
        store.repositoryURL = root
        try "marker".write(to: root.appendingPathComponent(".git/MERGE_HEAD"), atomically: true, encoding: .utf8)
        await store.refreshFileStatus()
        XCTAssertEqual(store.repositoryOperation, .merge)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git/MERGE_HEAD"))
        await store.refreshFileStatus()
        XCTAssertNil(store.repositoryOperation)
        store.repositoryOperation = .rebase
        store.repository = GitRepository(url: root.appendingPathComponent("different"))
        XCTAssertNil(store.repositoryOperation)
    }
}
