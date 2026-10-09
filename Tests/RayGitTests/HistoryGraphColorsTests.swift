import XCTest
@testable import RayGit
@testable import GitCore

final class HistoryGraphColorsTests: XCTestCase {
    private func commit(_ hash: String, parents: [String] = [], refs: [String] = []) -> GitCommit {
        GitCommit(hash: hash, parents: parents, author: "Test", date: .distantPast,
                  subject: hash, body: "", refs: refs)
    }

    func testLongLivedBranchesUseFixedColorsAndSolidWidths() {
        let commits = [
            commit("main", parents: ["base"], refs: ["HEAD -> main", "origin/main"]),
            commit("develop", parents: ["base"], refs: ["develop"]),
            commit("base")
        ]
        let plan = HistoryGraphStylePlan(commits: commits, remoteBranchNames: ["origin/main"])

        XCTAssertEqual(plan.lineStyle(for: "main"), .init(color: .blue, stroke: .solid, lineWidth: 3.5, variant: 0))
        XCTAssertEqual(plan.lineStyle(for: "develop"), .init(color: .cyan, stroke: .solid, lineWidth: 3, variant: 0))
        XCTAssertEqual(plan.lineStyle(for: "base").color, .blue)
        XCTAssertEqual(plan.referenceStyle(for: "HEAD -> main", commitHash: "main").color, .blue)
        XCTAssertEqual(plan.referenceStyle(for: "origin/main", commitHash: "main").color, .purple)
    }

    func testFeatureRemoteAndTagSemanticsUseIndependentChannels() {
        let commits = [
            commit("main", parents: ["base", "merged"], refs: ["main"]),
            commit("merged", parents: ["base"], refs: ["feature/merged"]),
            commit("open", parents: ["base"], refs: ["feature/open"]),
            commit("remote", parents: ["base"], refs: ["origin/review"]),
            commit("base", refs: ["tag: v1.0"])
        ]
        let plan = HistoryGraphStylePlan(commits: commits, remoteBranchNames: ["origin/review"])

        XCTAssertEqual(plan.lineStyle(for: "merged").stroke, .dashed)
        XCTAssertEqual(plan.lineStyle(for: "open").stroke, .dotted)
        XCTAssertEqual(plan.lineStyle(for: "remote").color, .purple)
        XCTAssertEqual(plan.lineStyle(for: "remote").stroke, .dotted)
        XCTAssertEqual(plan.referenceStyle(for: "tag: v1.0", commitHash: "base").color, .amber)
    }

    func testNodeShapesAndHeadRingRemainIndependentFromLineColor() {
        let commits = [
            commit("merge", parents: ["local", "side"], refs: ["HEAD -> main"]),
            commit("local", parents: ["base"]),
            commit("side", parents: ["base"]),
            commit("remote", refs: ["origin/review"]),
            commit("base")
        ]
        let plan = HistoryGraphStylePlan(commits: commits, remoteBranchNames: ["origin/review"])

        XCTAssertEqual(plan.nodeStyle(for: "merge").kind, .merge)
        XCTAssertTrue(plan.nodeStyle(for: "merge").isHead)
        XCTAssertEqual(plan.nodeStyle(for: "remote").kind, .remoteOnly)
        XCTAssertEqual(plan.nodeStyle(for: "local").kind, .ordinary)
        XCTAssertFalse(plan.nodeStyle(for: "local").isHead)
    }

    func testFeaturePaletteIsStableWhenCommitOrderChanges() {
        let first = commit("first", refs: ["feature/a"])
        let second = commit("second", refs: ["feature/b"])
        let ordered = HistoryGraphStylePlan(commits: [first, second], remoteBranchNames: [])
        let reordered = HistoryGraphStylePlan(commits: [second, first], remoteBranchNames: [])

        XCTAssertEqual(ordered.referenceStyle(for: "feature/a", commitHash: "first"), reordered.referenceStyle(for: "feature/a", commitHash: "first"))
        XCTAssertEqual(ordered.referenceStyle(for: "feature/b", commitHash: "second"), reordered.referenceStyle(for: "feature/b", commitHash: "second"))
        XCTAssertNotEqual(ordered.lineStyle(for: "first").color, ordered.lineStyle(for: "second").color)
    }

    func testReferenceClassificationSupportsVisibilityControls() {
        let plan = HistoryGraphStylePlan(
            commits: [commit("tip", refs: ["HEAD -> main", "origin/main", "tag: v1"])],
            remoteBranchNames: ["origin/main"]
        )

        XCTAssertTrue(plan.isCurrentReference("HEAD -> main"))
        XCTAssertTrue(plan.isRemoteReference("origin/main"))
        XCTAssertTrue(plan.isTagReference("tag: v1"))
        XCTAssertFalse(plan.isRemoteReference("HEAD -> main"))
    }
}
