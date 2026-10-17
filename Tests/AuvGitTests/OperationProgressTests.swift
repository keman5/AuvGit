import XCTest
import GitCore
import AuvGitLocalization
@testable import AuvGit

final class OperationProgressTests: XCTestCase {
    @MainActor
    func testFooterShowsOnlyTheCurrentPhaseForEveryOperation() throws {
        let store = RepositoryStore(persistsSession: false)
        let repository = GitRepository(url: URL(fileURLWithPath: "/tmp/footer-progress-repository"))
        store.repository = repository; store.repositoryURL = repository.url; store.isBusy = true
        defer { store.closeTransientSession() }
        for command in ["pull", "fetch", "push", "add", "commit", "stash", "checkout"] {
            store.beginUserOperation(command)
            let id = store.currentUserOperationID
            _ = store.progressHandler(for: repository, operationID: id)
            let event = try XCTUnwrap(GitProgressParser.parse("git " + command))
            store.receiveProgress(event, repository: repository, operationID: id)
            XCTAssertEqual(store.footerStatus, RepositoryStore.progressDetail(event.message))
            XCTAssertFalse(store.footerStatus.contains(" · "))
            let detail = try XCTUnwrap(GitProgressParser.parse("Receiving objects: 45% (9/20)"))
            store.receiveProgress(detail, repository: repository, operationID: id)
            XCTAssertEqual(store.footerStatus, RepositoryStore.progressDetail(detail.message))
            store.finishUserOperation(command, repository: repository)
            XCTAssertEqual(store.footerStatus, store.displayStatus)
        }
    }
    @MainActor
    func testProgressPhaseLocalizationPreservesCountsAndRate() {
        let suffix = ": 50% (1/2), 1.00 MiB | 2.00 MiB/s"
        XCTAssertEqual(RepositoryStore.progressDetail("Counting objects" + suffix), L10n.text("Counting objects", table: "OperationLog") + suffix)
        XCTAssertEqual(RepositoryStore.progressDetail("remote: Writing objects" + suffix), L10n.text("remote", table: "OperationLog") + ": " + L10n.text("Writing objects", table: "OperationLog") + suffix)
        XCTAssertEqual(RepositoryStore.progressDetail("Unknown phase: 12%"), "Unknown phase: 12%")
    }
    @MainActor
    func testProgressCannotReplaceFinishedOperationOrNewRepository() {
        let store = RepositoryStore(persistsSession: false)
        let repository = GitRepository(url: URL(fileURLWithPath: "/tmp/progress-repository"))
        store.repository = repository; store.repositoryURL = repository.url; store.isBusy = true
        store.beginUserOperation("Push")
        let id = store.currentUserOperationID
        _ = store.progressHandler(for: repository, operationID: id)
        let event = GitProgressParser.parse("Writing objects: 45%")!
        store.receiveProgress(event, repository: repository, operationID: id)
        XCTAssertEqual(store.liveProgress?.fraction, 0.45)
        store.finishUserOperation("Push", repository: repository)
        store.receiveProgress(event, repository: repository, operationID: id)
        XCTAssertNil(store.liveProgress)
        store.beginUserOperation("Pull")
        let nextID = store.currentUserOperationID
        _ = store.progressHandler(for: repository, operationID: nextID)
        store.receiveProgress(event, repository: repository, operationID: id)
        XCTAssertNil(store.liveProgress)
        store.repository = GitRepository(url: URL(fileURLWithPath: "/tmp/other-repository"))
        store.repositoryURL = store.repository?.url
        store.receiveProgress(event, repository: repository, operationID: nextID)
        XCTAssertNil(store.liveProgress)
        store.closeTransientSession()
    }
}
