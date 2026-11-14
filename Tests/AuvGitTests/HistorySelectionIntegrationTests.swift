import XCTest
import Combine
@testable import AuvGit
@testable import GitCore

@MainActor
final class HistorySelectionIntegrationTests: XCTestCase {
    func testFullLogTwoCommitAndVirtualSelectionRetainsComparisonAcrossRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("journal-range-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"]] {
            _ = try await GitProcess.run(at: root, arguments: args)
        }
        let repository = GitRepository(url: root)
        try "old\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try await repository.stage(paths: ["file"]); try await repository.commit(message: "base")
        let base = try await repository.workflowRevision("HEAD")
        try "new\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try await repository.stage(paths: ["file"]); try await repository.commit(message: "tip")
        let tip = try await repository.workflowRevision("HEAD")
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: false)
        defer { store.closeTransientSession() }
        store.repository = repository; store.repositoryURL = root
        store.commits = try await repository.log(); store.mode = "history"
        store.selectedPaths = ["untouched-workspace-selection"]
        let loaded = expectation(description: "journal files loaded")
        let observation = store.$commitFiles.filter { !$0.isEmpty }.first().sink { _ in loaded.fulfill() }
        store.selectHistoryRows([base, tip])
        await fulfillment(of: [loaded], timeout: 5)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(store.mode, "history")
        XCTAssertTrue(store.isHistoryDiff)
        XCTAssertEqual(store.selectedPaths, ["untouched-workspace-selection"])
        XCTAssertEqual(store.commitFiles.map(\.path), ["file"])
        XCTAssertEqual(store.historyComparisonTarget(for: "file"), .between(from: .commit(base), to: .commit(tip), path: "file"))
        await store.loadDiff()
        XCTAssertTrue(store.diffText.contains("-old")); XCTAssertTrue(store.diffText.contains("+new"))
        XCTAssertFalse(store.canMutateDisplayedDiff)
        store.reverseHistoryComparison()
        let reversed = expectation(description: "reversed journal files loaded")
        let reverseObservation = store.$commitFiles.filter { !$0.isEmpty }.first().sink { _ in reversed.fulfill() }
        await fulfillment(of: [reversed], timeout: 5)
        withExtendedLifetime(reverseObservation) {}
        XCTAssertEqual(store.historyComparisonTarget(for: "file"), .between(from: .commit(tip), to: .commit(base), path: "file"))
        store.selectHistoryRows([base, tip])
        XCTAssertEqual(store.historyComparisonTarget(for: "file"), .between(from: .commit(tip), to: .commit(base), path: "file"))

        try "working edit\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        store.selectHistoryRows([HistoryEndpoint.index.id, HistoryEndpoint.workingTree.id])
        let localRange = expectation(description: "local comparison range resolved")
        let localObservation = store.$historyComparisonRange.compactMap { $0 }.first().sink { _ in localRange.fulfill() }
        await fulfillment(of: [localRange], timeout: 5)
        withExtendedLifetime(localObservation) {}
        await store.refresh()
        XCTAssertEqual(store.selectedHistoryIDs, [HistoryEndpoint.index.id, HistoryEndpoint.workingTree.id])
        XCTAssertTrue(store.isHistoryDiff)
        store.selectedCommitPath = "file"
        try "new untracked\n".write(to: root.appendingPathComponent("new-file"), atomically: true, encoding: .utf8)
        await store.refreshFileStatus()
        XCTAssertTrue(store.commitFiles.contains { $0.path == "new-file" })
        XCTAssertEqual(store.selectedCommitPath, "file")
        XCTAssertTrue(store.isHistoryDiff)
        try await repository.stage(paths: ["file", "new-file"])
        try await repository.commit(message: "new HEAD")
        await store.refresh()
        XCTAssertEqual(store.selectedHistoryIDs, [HistoryEndpoint.index.id, HistoryEndpoint.workingTree.id])
        XCTAssertTrue(store.isHistoryDiff)
    }

    func testMainJournalSelectionAndRestoredLegacyStatePreserveWorkspacePreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("journal-workspace-" + UUID().uuidString)
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("journal-other-" + UUID().uuidString)
        for directory in [root, other] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"]] {
                _ = try await GitProcess.run(at: directory, arguments: args)
            }
        }
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        let repository = GitRepository(url: root)
        try "old\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try await repository.stage(paths: ["file"]); try await repository.commit(message: "base")
        let base = try await repository.workflowRevision("HEAD")
        try "new\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try await repository.stage(paths: ["file"]); try await repository.commit(message: "tip")
        let tip = try await repository.workflowRevision("HEAD")
        try "uncommitted\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        defer { store.closeTransientSession() }
        await store.open(root, promptsIfUnavailable: false)
        store.selectedPaths = ["file"]
        await store.loadDiff()
        let workspacePatch = store.diffText
        XCTAssertTrue(workspacePatch.contains("+uncommitted"))
        store.selectJournalRows([base, tip])
        XCTAssertEqual(store.selectedHistoryIDs, [base, tip])
        XCTAssertEqual(store.selectedPaths, ["file"])
        XCTAssertEqual(store.diffText, workspacePatch)
        XCTAssertFalse(store.isHistoryDiff)
        XCTAssertFalse(store.displaysHistorySelection)
        XCTAssertNil(store.historyComparisonRange)
        XCTAssertTrue(store.commitFiles.isEmpty)
        XCTAssertTrue(store.historyVirtualRows.isEmpty)
        store.selectHistoryRows([HistoryEndpoint.workingTree.id, tip])
        XCTAssertEqual(store.selectedHistoryIDs, [tip])
        XCTAssertEqual(store.diffText, workspacePatch)

        // Simulate a repository cache produced by the earlier journal UI.
        store.selectedHistoryIDs = [HistoryEndpoint.workingTree.id, tip]
        store.selectedCommit = HistoryEndpoint.workingTree.id
        store.displaysHistorySelection = true
        store.historyComparisonRange = HistoryComparisonRange(from: .commit(tip), to: .workingTree)
        store.diffText = "legacy historical comparison"
        await store.open(other, promptsIfUnavailable: false)
        await store.open(root, promptsIfUnavailable: false)
        XCTAssertFalse(store.displaysHistorySelection)
        XCTAssertFalse(store.isHistoryDiff)
        XCTAssertNil(store.historyComparisonRange)
        XCTAssertFalse(store.selectedHistoryIDs.contains(HistoryEndpoint.workingTree.id))
        XCTAssertNotEqual(store.selectedCommit, HistoryEndpoint.workingTree.id)
        XCTAssertNotEqual(store.diffText, "legacy historical comparison")
        await store.loadDiff()
        XCTAssertTrue(store.diffText.contains("+uncommitted"))
        XCTAssertEqual(store.selectedPaths, ["file"])
    }

}
