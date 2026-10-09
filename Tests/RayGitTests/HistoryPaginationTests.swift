import XCTest
@testable import RayGit
@testable import GitCore

@MainActor
final class HistoryPaginationTests: XCTestCase {
    func testPrefetchGateRequestsOncePerCommitCountNearTheEnd() {
        var gate = HistoryPaginationGate(prefetchDistance: 10)

        XCTAssertFalse(gate.shouldRequestMore(visibleIndex: 14, commitCount: 25, hasMore: true, isLoading: false))
        XCTAssertTrue(gate.shouldRequestMore(visibleIndex: 15, commitCount: 25, hasMore: true, isLoading: false))
        XCTAssertFalse(gate.shouldRequestMore(visibleIndex: 24, commitCount: 25, hasMore: true, isLoading: false))
        XCTAssertTrue(gate.shouldRequestMore(visibleIndex: 40, commitCount: 50, hasMore: true, isLoading: false))
    }

    func testPrefetchGateSuppressesLoadingAndTerminalStates() {
        var gate = HistoryPaginationGate(prefetchDistance: 10)

        XCTAssertFalse(gate.shouldRequestMore(visibleIndex: 20, commitCount: 25, hasMore: true, isLoading: true))
        XCTAssertFalse(gate.shouldRequestMore(visibleIndex: 20, commitCount: 25, hasMore: false, isLoading: false))
        XCTAssertFalse(gate.shouldRequestMore(visibleIndex: 0, commitCount: 0, hasMore: true, isLoading: false))
    }

    func testSwitchingRepositoriesRetainsLoadedHistoryDepthInMemory() async throws {
        let defaults = UserDefaults.standard
        let key = "preferences.historyPageSize"
        let previous = defaults.object(forKey: key)
        defaults.set(25, forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeRepository(first, commits: 30)
        try await makeRepository(second, commits: 1)

        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        defer { store.closeTransientSession() }
        await store.open(first)
        XCTAssertEqual(store.commits.count, 25)
        await store.loadHistory(reset: false)
        XCTAssertEqual(store.commits.count, 30)

        await store.open(second)
        XCTAssertEqual(store.commits.count, 1)
        await store.open(first)

        XCTAssertEqual(store.commits.count, 30)
        XCTAssertFalse(store.hasMore)
    }

    private func makeRepository(_ url: URL, commits: Int) async throws {
        for arguments in [
            ["init", "-b", "main"],
            ["config", "user.name", "Test"],
            ["config", "user.email", "test@example.invalid"],
            ["config", "commit.gpgsign", "false"]
        ] {
            _ = try await GitProcess.run(at: url, arguments: arguments)
        }
        for index in 0..<commits {
            _ = try await GitProcess.run(at: url, arguments: ["commit", "--allow-empty", "-m", "Commit \(index)"])
        }
    }
}
