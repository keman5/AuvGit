import XCTest
import Combine
@testable import AuvGit

@MainActor
final class SessionSavePerformanceTests: XCTestCase {
    func testLiveWorkspaceChangesDoNotRequestSessionEncoding() {
        let store = RepositoryStore(persistsSession: false)
        var saves = 0
        let subscription = store.sessionChanges.sink { saves += 1 }
        defer { subscription.cancel(); store.closeTransientSession() }
        XCTAssertEqual(saves, 0, "Subscribing must not replay every persisted field")
        for index in 0..<100 {
            store.files = []
            store.filesGeneration = UUID()
            store.diffText = "diff \(index)"
            store.branch = "branch-\(index)"
            store.commits = []
            store.loadingDiff = index.isMultiple(of: 2)
            store.isBusy = index.isMultiple(of: 2)
            store.repositoryChangeCounts = ["/tmp/repository": index]
        }
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(store.sessionEncodingCount, 0)
    }
    func testPersistedViewFieldsPublishSessionChanges() {
        let store = RepositoryStore(persistsSession: false)
        var saves = 0
        let subscription = store.sessionChanges.sink { saves += 1 }
        defer { subscription.cancel(); store.closeTransientSession() }
        let changes: [() -> Void] = [
            { store.repositoryURL = URL(fileURLWithPath: "/tmp/session-publisher-test") },
            { store.openRepositories = ["/tmp/session-publisher-test"] },
            { store.commitMessage = "draft" }, { store.amend = true },
            { store.historySearch = "query" }, { store.historyAuthor = "author" },
            { store.historyPath = "source.swift" }, { store.historyRef = "main" },
            { store.selectedPaths = ["source.swift"] }, { store.selectedCommit = "abc" },
            { store.selectedCommitPath = "source.swift" }, { store.mode = "history" },
            { store.fileFilter = "source" }, { store.stagedDiff = true },
            { store.ignoreWhitespace = true }
        ]
        for change in changes {
            let previous = saves
            change()
            XCTAssertEqual(saves, previous + 1)
        }
        XCTAssertEqual(saves, changes.count)
        store.flushSession()
        XCTAssertEqual(store.sessionEncodingCount, 0, "A transient publisher test must never persist live preferences")
    }
}
