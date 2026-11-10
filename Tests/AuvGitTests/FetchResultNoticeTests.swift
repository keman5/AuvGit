import XCTest
import SwiftUI
import AuvGitLocalization
@testable import AuvGit
@testable import GitCore

@MainActor
final class FetchResultNoticeTests: XCTestCase {
    func testNoChangesStillExplainsBrokenUpstreamInEveryLanguage() {
        let previous = UserDefaults.standard.object(forKey: L10n.preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: L10n.preferenceKey) }
        let missing = MissingRemoteUpstream(localBranch: "main", remote: "origin", mergeRef: "refs/heads/dev", availableBranches: ["origin/main"])
        let outcome = FetchOperationOutcome(addedBranches: [], updatedBranches: [], prunedBranches: [], missingUpstream: missing, upstreamCheckFailure: nil)
        for language in ["en", "zh-Hans", "zh-Hant", "ja"] {
            UserDefaults.standard.set(language, forKey: L10n.preferenceKey)
            let message = FetchResultNotice(outcome: outcome).message
            XCTAssertTrue(message.contains(networkText("fetchNoChanges")))
            XCTAssertTrue(message.contains("origin/dev"))
            XCTAssertTrue(message.contains("main"))
            XCTAssertFalse(message.contains("fetchMissingUpstream"))
        }
    }

    func testSummaryDistinguishesAddedUpdatedAndPrunedBranchesAndRedactsCheckFailure() {
        let outcome = FetchOperationOutcome(addedBranches: ["origin/new"], updatedBranches: ["origin/main"], prunedBranches: ["origin/dev"], missingUpstream: nil,
            upstreamCheckFailure: "unrecognized error token=private-fixture")
        let message = FetchResultNotice(outcome: outcome).message
        for name in ["origin/new", "origin/main", "origin/dev"] { XCTAssertTrue(message.contains(name)) }
        XCTAssertTrue(message.contains(networkText("fetchUpstreamCheckFailed")))
        XCTAssertFalse(message.contains("private-fixture"))
        XCTAssertFalse(message.contains(networkText("fetchNoChanges")))
    }

    func testMissingRemoteRefProvidesRecoveryGuidanceInsteadOfRawFatal() {
        let error = GitError("fatal: couldn't find remote ref refs/heads/dev")
        let expected = "The tracked remote branch is unavailable. Fetch and choose an existing tracking branch."
        XCTAssertEqual(GitFailureSummary.key(for: error.localizedDescription), expected)
        XCTAssertEqual(PullResultNotice(error: error).message, L10n.text(expected, table: "OperationLog"))
        XCTAssertEqual(GitFailureSummary.key(for: "Your configuration specifies to merge with the ref 'refs/heads/dev' from the remote, but no such ref was fetched."), expected)
    }

    func testResultSheetRendersWithoutOpeningAWindowOrTakingFocus() {
        let store = RepositoryStore(persistsSession: false)
        let repository = GitRepository(url: URL(fileURLWithPath: "/tmp/fetch-result-fixture"))
        store.repository = repository; store.repositoryURL = repository.url
        let outcome = FetchOperationOutcome(addedBranches: [], updatedBranches: [], prunedBranches: [],
            missingUpstream: MissingRemoteUpstream(localBranch: "main", remote: "origin", mergeRef: "refs/heads/dev", availableBranches: ["origin/main"]), upstreamCheckFailure: nil)
        let host = NSHostingView(rootView: FetchResultSheet(store: store,
            prompt: FetchResultPrompt(repository: repository, outcome: outcome), close: {}))
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, 520, accuracy: 1)
        XCTAssertGreaterThan(host.fittingSize.height, 100)
        XCTAssertLessThan(host.fittingSize.height, 600)
        XCTAssertNil(host.window)
    }
}
