import XCTest
@testable import AuvGit
@testable import GitCore

@MainActor
final class LogBranchNavigationTests: XCTestCase {
    private func fixture() async throws -> (URL, RepositoryStore, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let repo = GitRepository(url: root)
            for args in [["init", "-b", "main"], ["config", "user.name", "Test"],
                         ["config", "user.email", "fixture@example.invalid"], ["config", "commit.gpgsign", "false"],
                         ["config", "core.hooksPath", root.appendingPathComponent("no-hooks").path],
                         ["commit", "--allow-empty", "-m", "base"]] {
                _ = try await GitProcess.run(at: root, arguments: args)
            }
            let base = try await repo.workflowRevision("HEAD")
            let tree = try await repo.workflowRead(["rev-parse", "HEAD^{tree}"]).trimmingCharacters(in: .newlines)
            for (ref, subject) in [("refs/heads/review", "local tip"), ("refs/remotes/origin/review", "remote tip")] {
                let hash = try await repo.workflowRead(["commit-tree", tree, "-p", base, "-m", subject]).trimmingCharacters(in: .newlines)
                _ = try await repo.workflowRead(["update-ref", ref, hash])
            }
            let store = RepositoryStore(persistsSession: false, usesCheckedHistoryScope: true)
            store.repository = repo; store.repositoryURL = root; store.mode = "history"
            store.branches = try await repo.branches()
            store.historyRef = "refs/heads/main"
            store.checkedHistoryRefs = ["HEAD", "refs/heads/review", "refs/remotes/origin/review"]
            store.commits = try await repo.log(limit: 1, ref: "HEAD")
            store.selectedCommit = base
            return (root, store, base)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func testSingleCheckedLocalAndRemoteBranchesSelectTheirExactTipsWithoutChangingScope() async throws {
        let (root, store, base) = try await fixture()
        defer { store.closeTransientSession(); try? FileManager.default.removeItem(at: root) }
        let navigation = LogBranchSelection(), scope = store.currentHistoryScope
        let sidebarNavigation = store.historyNavigationGeneration
        for ref in ["refs/heads/review", "refs/remotes/origin/review", "HEAD"] {
            let expected = try await store.repository!.workflowRevision(ref)
            let before = navigation.navigationGeneration
            await navigation.select([ref], in: store)?.value
            XCTAssertEqual(store.selectedCommit, expected)
            XCTAssertTrue(store.commits.contains { $0.hash == expected }, "A tip outside the loaded page must become visible")
            XCTAssertEqual(store.currentHistoryScope, scope, "Selecting a row must not alter checked branches or filters")
            XCTAssertEqual(store.historyNavigationGeneration, sidebarNavigation, "Do not reset sidebar selection")
            XCTAssertNotEqual(navigation.navigationGeneration, before, "The commit list must scroll, including repeated selection")
        }
        XCTAssertEqual(store.selectedCommit, base)
        XCTAssertNil(store.error)
    }

    func testBatchEmptyUncheckedAndNonBranchSelectionLeaveCommitUntouched() async throws {
        let (root, store, base) = try await fixture()
        defer { store.closeTransientSession(); try? FileManager.default.removeItem(at: root) }
        let navigation = LogBranchSelection(), generation = navigation.navigationGeneration
        for refs: Set<String> in [["refs/heads/review", "refs/remotes/origin/review"], [], ["refs/heads/main"], [HistoryBranchScope.recyclable], ["refs/tags/v1"]] {
            XCTAssertNil(navigation.select(refs, in: store))
            XCTAssertEqual(store.selectedCommit, base)
            XCTAssertEqual(navigation.navigationGeneration, generation)
        }
    }

    func testBatchSelectionCancelsPendingSingleSelection() async throws {
        let (root, store, base) = try await fixture()
        defer { store.closeTransientSession(); try? FileManager.default.removeItem(at: root) }
        let navigation = LogBranchSelection()
        let pending = try XCTUnwrap(navigation.select(["refs/heads/review"], in: store))
        XCTAssertNil(navigation.select(["refs/heads/review", "HEAD"], in: store))
        await pending.value
        XCTAssertEqual(store.selectedCommit, base)
        XCTAssertTrue(pending.isCancelled)
    }

    func testLatestSelectionWinsAndExplicitCommitSelectionIsPreserved() async throws {
        let (root, store, base) = try await fixture()
        defer { store.closeTransientSession(); try? FileManager.default.removeItem(at: root) }
        let navigation = LogBranchSelection()
        let first = navigation.select(["refs/heads/review"], in: store)
        let second = navigation.select(["refs/remotes/origin/review"], in: store)
        await first?.value; await second?.value
        let remoteTip = try await store.repository!.workflowRevision("refs/remotes/origin/review")
        XCTAssertEqual(store.selectedCommit, remoteTip)
        let pending = navigation.select(["refs/heads/review"], in: store)
        store.selectedCommit = base
        await pending?.value
        XCTAssertEqual(store.selectedCommit, base, "A delayed branch read must not replace a newer explicit commit choice")
    }

    func testUncheckingBranchOrNavigatingElsewhereRejectsPendingResult() async throws {
        let (root, store, base) = try await fixture()
        defer { store.closeTransientSession(); try? FileManager.default.removeItem(at: root) }
        let navigation = LogBranchSelection()
        let pending = navigation.select(["refs/heads/review"], in: store)
        store.checkedHistoryRefs?.remove("refs/heads/review")
        await pending?.value
        XCTAssertEqual(store.selectedCommit, base)
        let next = navigation.select(["refs/remotes/origin/review"], in: store)
        store.historyNavigationGeneration = UUID()
        await next?.value
        XCTAssertEqual(store.selectedCommit, base)
    }
}
