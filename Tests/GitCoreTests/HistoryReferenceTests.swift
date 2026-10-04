import XCTest
@testable import GitCore

final class HistoryReferenceTests: XCTestCase {
    private let branches = [
        GitBranch(name: "main", isCurrent: true, isRemote: false),
        GitBranch(name: "origin/main", isCurrent: false, isRemote: true)
    ]

    func testSidebarReferencesUseFullLocalAndRemoteNames() {
        XCTAssertEqual(HistoryReference.canonical("main", branches: branches), "refs/heads/main")
        XCTAssertEqual(HistoryReference.canonical("origin/main", branches: branches), "refs/remotes/origin/main")
    }

    func testExactReferencesAndPinnedRevisionsRemainUnchanged() {
        for reference in ["refs/heads/main", "refs/remotes/origin/main", "refs/tags/v1.0", "HEAD", "stash@{2}", "0123456789abcdef"] {
            XCTAssertEqual(HistoryReference.canonical(reference, branches: branches), reference)
        }
        XCTAssertNil(HistoryReference.canonical(nil, branches: branches))
        XCTAssertNil(HistoryReference.canonical("", branches: branches))
    }
    func testAmbiguousShortBranchNamesDoNotChooseLocalOrRemoteArbitrarily() {
        let collision = branches + [GitBranch(name: "origin/main", isCurrent: false, isRemote: false)]
        XCTAssertEqual(HistoryReference.canonical("origin/main", branches: collision), "origin/main")
        XCTAssertEqual(HistoryReference.canonical("refs/remotes/origin/main", branches: collision), "refs/remotes/origin/main")
        XCTAssertEqual(HistoryReference.canonical("refs/heads/origin/main", branches: collision), "refs/heads/origin/main")
    }
}
