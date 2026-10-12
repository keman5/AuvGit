import XCTest
@testable import RayGit
@testable import GitCore

final class HistoryGraphColorsTests: XCTestCase {
    func testAllBrokenLineKindsUseTheSameRoundedShortDashPattern() {
        for stroke in [HistoryGraphStrokeKind.dashed, .dotted] {
            XCTAssertEqual(HistoryGraphLineStyle(color: .gray, stroke: stroke, lineWidth: 1.2, variant: 0).dashPattern, [4, 3])
        }
    }
    private func commit(_ hash: String, parents: [String] = [], refs: [String] = []) -> GitCommit {
        GitCommit(hash: hash, parents: parents, author: "Test", date: .distantPast,
                  subject: hash, body: "", refs: refs)
    }

    func testLocalSideBranchesAndIncomingBranchesUseRoundedShortDashes() {
        let commits = [
            commit("head", parents: ["local"], refs: ["HEAD -> main"]),
            commit("local", parents: ["published"]),
            commit("side", parents: ["published"], refs: ["feature/work"]),
            commit("incoming", parents: ["published"], refs: ["origin/review"]),
            commit("published", refs: ["origin/main"])
        ]
        let plan = HistoryGraphStylePlan(commits: commits, remoteBranchNames: ["origin/main", "origin/review"],
            localUnpushedHashes: ["head", "local", "side"])
        for hash in ["head", "local", "side"] {
            XCTAssertEqual(plan.lineStyle(for: hash).stroke, .dashed)
            XCTAssertEqual(plan.lineStyle(for: hash).dashPattern, [4, 3])
        }
        XCTAssertEqual(plan.lineStyle(for: "head").color, .orange)
        XCTAssertEqual(plan.lineStyle(for: "published").stroke, .solid)
        XCTAssertEqual(plan.lineStyle(for: "incoming").stroke, .dashed)
        XCTAssertEqual(plan.nodeStyle(for: "incoming").color, .green)
        XCTAssertEqual(plan.nodeStyle(for: "incoming").kind, .remoteOnly)
        XCTAssertEqual(plan.referenceStyle(for: "HEAD -> main", commitHash: "head").stroke, .dashed)
        XCTAssertEqual(plan.referenceStyle(for: "origin/main", commitHash: "published").stroke, .solid)
    }

    func testPushingTheSameHistoryChangesDashesToSolidWithoutChangingLaneColor() {
        let commits = [commit("head", parents: ["base"], refs: ["HEAD -> main"]), commit("base")]
        let before = HistoryGraphStylePlan(commits: commits, remoteBranchNames: [], localUnpushedHashes: ["head"])
        let after = HistoryGraphStylePlan(commits: commits, remoteBranchNames: [], localUnpushedHashes: [])
        XCTAssertEqual(before.lineStyle(for: "head").stroke, .dashed)
        XCTAssertEqual(after.lineStyle(for: "head").stroke, .solid)
        XCTAssertEqual(before.lineStyle(for: "head").color, .orange)
        XCTAssertEqual(after.lineStyle(for: "head").color, .blue)
        XCTAssertEqual(before.nodeStyle(for: "head").color, .orange)
    }

    func testUnpushedEdgeStaysDashedUntilThePublishedParentNode() {
        let commits = [commit("head", parents: ["base"], refs: ["HEAD -> main"]),
                       commit("base", parents: ["root"], refs: ["origin/main"]), commit("root")]
        let plan = HistoryGraphStylePlan(commits: commits, remoteBranchNames: ["origin/main"], localUnpushedHashes: ["head"])
        let graph = CommitGraph(commits: commits)
        XCTAssertEqual(plan.lineStyle(for: "base").stroke, .solid)
        XCTAssertTrue(graph.rows[0].segments.allSatisfy { plan.lineStyle(for: $0).stroke == .dashed })
        let parentRow = graph.rows[1]
        XCTAssertEqual(plan.lineStyle(for: parentRow.segments.first { $0.fromY == 0 }!).stroke, .dashed)
        XCTAssertEqual(plan.lineStyle(for: parentRow.segments.first { $0.fromY == 0.5 }!).stroke, .solid)
    }

    func testMergeConnectionsKeepTheSideBranchColorAtSharedAncestors() throws {
        let commits = [commit("merge", parents: ["main", "side"], refs: ["HEAD -> main"]),
            commit("main", parents: ["base"], refs: ["origin/main"]),
            commit("side", parents: ["base"], refs: ["feature/login"]), commit("base")]
        let plan = HistoryGraphStylePlan(commits: commits, remoteBranchNames: ["origin/main"], localUnpushedHashes: ["side"])
        let graph = CommitGraph(commits: commits)
        let enteringSide = try XCTUnwrap(graph.rows[0].segments.first { $0.lineageHash == "side" })
        let leavingSide = try XCTUnwrap(graph.rows[2].segments.first { $0.sourceHash == "side" && $0.lineageHash == "base" })
        XCTAssertEqual(plan.lineStyle(for: enteringSide).color, .gray)
        XCTAssertEqual(plan.lineStyle(for: enteringSide).stroke, .dashed, "The merge curve must use the incoming branch's dashes")
        XCTAssertEqual(plan.lineStyle(for: leavingSide).color, .orange, "Unpushed side edges stay orange until the published parent")
        XCTAssertEqual(plan.lineStyle(for: leavingSide).stroke, .dashed)
        XCTAssertEqual(plan.nodeStyle(for: "base").color, .blue)
    }

    func testCurrentAndOtherBranchesUseTwoCompactStyles() {
        let commits = [
            commit("main", parents: ["base"], refs: ["HEAD -> main", "origin/main"]),
            commit("develop", parents: ["base"], refs: ["develop"]),
            commit("base")
        ]
        let plan = HistoryGraphStylePlan(commits: commits, remoteBranchNames: ["origin/main"])

        XCTAssertEqual(plan.lineStyle(for: "main"), .init(color: .blue, stroke: .solid, lineWidth: 1.8, variant: 0))
        XCTAssertEqual(plan.lineStyle(for: "develop"), .init(color: .gray, stroke: .dashed, lineWidth: 1.2, variant: 0))
        XCTAssertEqual(plan.lineStyle(for: "base").color, .blue)
        XCTAssertEqual(plan.referenceStyle(for: "HEAD -> main", commitHash: "main").color, .blue)
        XCTAssertEqual(plan.referenceStyle(for: "origin/main", commitHash: "main").color, .blue)
        XCTAssertEqual(plan.referenceStyle(for: "origin/main", commitHash: "main").stroke, .solid)
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
        XCTAssertEqual(plan.lineStyle(for: "open").stroke, .dashed)
        XCTAssertEqual(plan.lineStyle(for: "remote").color, .green)
        XCTAssertEqual(plan.lineStyle(for: "remote").stroke, .dashed)
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

    func testPublishedBranchesStillMatchReferenceLineTypesInAllFourStates() {
        let commits = [commit("remoteCurrent", parents: ["head"], refs: ["origin/main"]),
            commit("remoteOther", parents: ["base"], refs: ["origin/review"]),
            commit("head", parents: ["base"], refs: ["HEAD -> main"]),
            commit("side", parents: ["base"], refs: ["feature/login", "origin/feature/login"]), commit("base")]
        let plan = HistoryGraphStylePlan(commits: commits,
            remoteBranchNames: ["origin/main", "origin/review", "origin/feature/login"], localUnpushedHashes: [])
        XCTAssertEqual(plan.lineStyle(for: "head").stroke, .solid)
        XCTAssertEqual(plan.lineStyle(for: "side").stroke, .dashed)
        XCTAssertEqual(plan.lineStyle(for: "remoteCurrent").stroke, .dashed)
        XCTAssertEqual(plan.lineStyle(for: "remoteCurrent").color, .green)
        XCTAssertEqual(plan.lineStyle(for: "remoteOther").stroke, .dashed)
        XCTAssertEqual(plan.lineStyle(for: "remoteOther").color, .green)
        XCTAssertEqual(plan.lineStyle(for: "remoteOther").dashPattern, [4, 3])
    }

    func testOtherBranchesRemainMutedWhenCommitOrderChanges() {
        let first = commit("first", refs: ["feature/a"])
        let second = commit("second", refs: ["feature/b"])
        let ordered = HistoryGraphStylePlan(commits: [first, second], remoteBranchNames: [])
        let reordered = HistoryGraphStylePlan(commits: [second, first], remoteBranchNames: [])

        XCTAssertEqual(ordered.referenceStyle(for: "feature/a", commitHash: "first"), reordered.referenceStyle(for: "feature/a", commitHash: "first"))
        XCTAssertEqual(ordered.referenceStyle(for: "feature/b", commitHash: "second"), reordered.referenceStyle(for: "feature/b", commitHash: "second"))
        XCTAssertEqual(ordered.lineStyle(for: "first").color, .gray)
        XCTAssertEqual(ordered.lineStyle(for: "second").color, .gray)
    }

    func testCurrentFeatureAndCustomUpstreamWinSharedAncestryWithoutHighlightingMergeSide() {
        let commits = [
            commit("head", parents: ["base", "side"], refs: ["HEAD -> feature/work"]),
            commit("remote", parents: ["head"], refs: ["upstream/review"]),
            commit("side", parents: ["base"], refs: ["main", "origin/feature/work"]),
            commit("base")
        ]
        let plan = HistoryGraphStylePlan(commits: commits, remoteBranchNames: ["upstream/review", "origin/feature/work"],
            currentBranch: GitBranch(name: "feature/work", isCurrent: true, isRemote: false, upstream: "upstream/review"))
        XCTAssertEqual(plan.lineStyle(for: "head").color, .blue)
        XCTAssertEqual(plan.lineStyle(for: "base").color, .blue)
        XCTAssertEqual(plan.lineStyle(for: "side").color, .gray)
        XCTAssertEqual(plan.lineStyle(for: "remote").color, .green)
        XCTAssertEqual(plan.lineStyle(for: "remote").stroke, .dashed)
        XCTAssertEqual(plan.nodeStyle(for: "remote").kind, .remoteOnly)
        XCTAssertEqual(plan.referenceStyle(for: "origin/feature/work", commitHash: "side").color, .gray)
        XCTAssertEqual(plan.referenceLabel("HEAD -> feature/work"), "→ feature/work")
        XCTAssertEqual(plan.referenceLabel("upstream/review"), "○ upstream/review")
    }

    func testDetachedHeadIsLocalAndRemoteMergeRemainsHollow() {
        let commits = [
            commit("head", refs: ["HEAD", "origin/main"]),
            commit("remote", parents: ["left", "right"], refs: ["origin/review"]),
            commit("left"), commit("right")
        ]
        let plan = HistoryGraphStylePlan(commits: commits, remoteBranchNames: ["origin/main", "origin/review"])
        XCTAssertEqual(plan.nodeStyle(for: "head").kind, .ordinary)
        XCTAssertTrue(plan.nodeStyle(for: "head").isHead)
        XCTAssertEqual(plan.nodeStyle(for: "remote").kind, .remoteOnly)
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
        XCTAssertTrue(plan.isRemoteReference("refs/remotes/upstream/review"))
    }
}
