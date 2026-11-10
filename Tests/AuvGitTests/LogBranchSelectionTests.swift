import XCTest
@testable import AuvGit
@testable import GitCore

@MainActor
final class LogBranchSelectionTests: XCTestCase {
    func testCheckingAndUncheckingRefsReloadsScopeWithoutNavigatingSidebar() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            var saved = UserDefaults.standard.dictionary(forKey: HistoryBranchScope.preferenceKey) ?? [:]
            saved.removeValue(forKey: HistoryBranchScope.repositoryKey(root))
            UserDefaults.standard.set(saved, forKey: HistoryBranchScope.preferenceKey)
            try? FileManager.default.removeItem(at: root)
        }
        let repo = GitRepository(url: root)
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"],
                     ["config", "user.email", "fixture@example.invalid"], ["config", "commit.gpgsign", "false"],
                     ["config", "core.hooksPath", root.appendingPathComponent("no-hooks").path],
                     ["commit", "--allow-empty", "-m", "base"]] {
            _ = try await GitProcess.run(at: root, arguments: args)
        }
        let base = try await repo.workflowRevision("HEAD")
        let tree = try await repo.workflowRead(["rev-parse", "HEAD^{tree}"]).trimmingCharacters(in: .newlines)
        let localRef = "refs/heads/feature", remoteRef = "refs/remotes/origin/review"
        for (ref, subject) in [(localRef, "feature"), (remoteRef, "review")] {
            let hash = try await repo.workflowRead(["commit-tree", tree, "-p", base, "-m", subject]).trimmingCharacters(in: .newlines)
            _ = try await repo.workflowRead(["update-ref", ref, hash])
        }
        let store = RepositoryStore(persistsSession: false, usesCheckedHistoryScope: true)
        defer { store.closeTransientSession() }
        store.repository = repo; store.repositoryURL = root; store.mode = "history"
        store.branches = try await repo.branches()
        store.historyRef = "refs/heads/main"
        store.checkedHistoryRefs = ["refs/heads/main"]
        await store.loadHistory(reset: true)
        let navigation = store.historyNavigationGeneration

        // The sidebar's mouse selection can differ from the branch used to open
        // the window. Only explicit navigation may reset that independent selection.
        let changes: [(String, Bool, Set<String>)] = [
            (localRef, true, ["base", "feature"]),
            (remoteRef, true, ["base", "feature", "review"]),
            ("refs/heads/main", false, ["base", "feature", "review"]),
            (localRef, false, ["base", "review"]),
            (remoteRef, false, [])
        ]
        var expectedRefs = Set(["refs/heads/main"])
        for (ref, checked, subjects) in changes {
            store.setHistoryBranchChecked(ref, checked: checked)
            if checked { expectedRefs.insert(ref) } else { expectedRefs.remove(ref) }
            XCTAssertEqual(store.historyNavigationGeneration, navigation, "Changing checks must not restore the opening branch highlight")
            let deadline = ContinuousClock.now + .seconds(5)
            // A checkbox schedules its read; yield once before observing completion.
            await Task.yield()
            while (store.loadingHistory || Set(store.commits.map(\.subject)) != subjects), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertFalse(store.loadingHistory)
            XCTAssertNil(store.error)
            XCTAssertEqual(Set(store.commits.map(\.subject)), subjects)
            XCTAssertEqual(store.checkedHistoryRefs, expectedRefs)
            XCTAssertEqual(HistoryBranchScope.load(repository: root), expectedRefs)
            XCTAssertEqual(store.historyRef, "refs/heads/main")
            XCTAssertEqual(store.historyNavigationGeneration, navigation)
        }
    }
}
